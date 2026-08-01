module cherry.core.dispatcher;

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import core.time : Duration, MonoTime, dur;
import std.container.dlist : DList;

import cherry.core.value;
import cherry.platform;
import cherry.core.multicast;

/**
 * An enunmeration describing the priorities at which operations 
 * can be invoked via the Dispatcher.
 */
enum DispatcherPriority : int
{
    invalid         = -1,
    /// Operations at this priority are not processed
    inactive        = 0,
    /// Operations at this priority are processed when the system is idle
    systemIdle      = 1,
    /// Operations at this priority are processed when the application is idle
    applicationIdle = 2,
    /// Operations at this priority are processed when the context is idle
    contextIdle     = 3,
    /// Operations at this priority are processed after all other non-idle operations are done
    background      = 4,
    /// Operations at this priority are processed at the same priority as input
    input           = 5,
    /// Operations at this priority are processed when layout and render is
	/// done but just before items at input priority are serviced. Specifically
	/// this is used while firing the Loaded event
    loaded          = 6,
    /// Operations at this priority are processed at the same priority as rendering
    render          = 7,
    /// Operations at this priority are processed at the same priority as data binding
    dataBind        = 8,
    /// Operations at this priority are processed at normal priority
    normal          = 9,
    /// Operations at this priority are processed before other asynchronous operations
    send            = 10
}

/**
 * Whether the value names one of the queue's priority bands.
 *
 * The bands are array indices, so `invalid` -- or any integer cast into the
 * enum from outside its range -- would index past the array.  The checks
 * below therefore throw rather than assert: contracts are compiled out in
 * release builds, which is exactly where an out-of-range index does damage
 * instead of tripping a bounds check.
 */
private bool isQueueBand(DispatcherPriority p) pure nothrow @nogc
{
    return p >= DispatcherPriority.inactive && p <= DispatcherPriority.send;
}

/**
 * An enunmeration describing the status of a DispatcherOperation
 */
enum OperationStatus 
{ 
    /// The operation is pending in queue
	pending,
    /// The operation has started executing, but has not completed yet
	executing, 
    /// The operation has been completed
	completed, 
    /// The operation has been aborted
	aborted 
}

/**
 *
 */
class DispatcherObject
{
    package this(shared(Dispatcher) dispatcher)
	{
        _dispatcher = dispatcher;
	}

    this()
	{
		// Bind to the thread's dispatcher if it already has one.  Constructing
		// an object must not conjure a dispatcher -- and, on Windows, a
		// message-only window -- as a side effect; the application creates it
		// explicitly.  An object with no dispatcher simply has no affinity.
		_dispatcher = Dispatcher.currentOrNull;
	}

   /**
    * Returns the Dispatcher that this object is associated with.  
	* This property is thread-safe.
    */
    @property shared(Dispatcher) dispatcher() shared pure nothrow @nogc
    {
        return _dispatcher;
    }

    @property Dispatcher dispatcher() pure nothrow @nogc
    {
        return cast(Dispatcher) _dispatcher;
    }

   /**
    * Whether the calling thread is the dispatcher's thread.
    */
    bool checkAccess() shared const
    {
        return _dispatcher is null || Thread.getThis().id == _dispatcher.threadId;
    }

    bool checkAccess() const
    {
        return _dispatcher is null || Thread.getThis().id == _dispatcher.threadId;
    }

   /**
    * Throws when the calling thread is not the dispatcher's thread.
    */
    void verifyAccess() shared const
    {
        if (!checkAccess())
            throw new Exception("The calling thread cannot access this object because a different thread owns it.");
    }

    void verifyAccess() const
    {
		(cast (shared) this).verifyAccess();
    }

private:
    shared(Dispatcher) _dispatcher;
}

/**
 * Class PriorityQueue represents a thread-safe Dispatcher queue. 
 * Only this class may safe change protected fields _qNode and _priority
 * of class DispatcherOperation and protect his by own mutex.
 */
private final class PriorityQueue
{
    shared this()
	{
        _m = new shared Mutex;
        _highestPriority = DispatcherPriority.inactive;
	}

    @property DispatcherPriority highestPriority() const shared pure nothrow @nogc
	{
        return atomicLoad(_highestPriority);
	}

	/**
	 * Adds an operation to its priority band.
	 *
	 * Returns: the queue node, or null once the queue has been closed, so the
	 * caller can reject the operation instead of parking it in a queue nobody
	 * will ever drain.
	 * Testing the flag here, under the queue's own mutex, is what makes the
	 * check atomic with respect to close().
	 */
	Node* enqueue(shared(DispatcherOperation) op) shared
	in {
        assert(op !is null);
	}
    do {
        auto self = cast(PriorityQueue) this;
        auto o    = cast(DispatcherOperation) op;

        synchronized (self._m)
		{
           if (self._closed)
               return null;

           auto node = new Node(null, null, op);
           self.linkBack(node, o._priority);
           o._qNode = node;
           return node;
		}
    }

	/**
	 * Closes the queue and hands back everything still parked in it, so the
	 * caller can drive those operations to a terminal status.  Idempotent: a
	 * second call returns nothing.
	 */
	shared(DispatcherOperation)[] close() shared
	{
        auto self = cast(PriorityQueue) this;

        synchronized (self._m)
		{
            if (self._closed)
                return null;

            self._closed = true;

            shared(DispatcherOperation)[] pending;

            foreach (p; 0 .. self._queue.length)
			{
                for (auto node = self._queue[p].head; node !is null; )
				{
                    auto next = node.next;
                    pending ~= node.op;
                    (cast(DispatcherOperation) node.op)._qNode = null;
                    node.prev = null;
                    node.next = null;
                    node = next;
				}

                self._queue[p] = QueueList.init;
			}

            atomicStore(self._highestPriority, DispatcherPriority.inactive);
            return pending;
		}
	}

    shared(DispatcherOperation) dequeue() shared 
	{ 
		auto self = cast(PriorityQueue) this;

		synchronized (self._m)
		{
			immutable p = atomicLoad(self._highestPriority);
			if (p == DispatcherPriority.inactive)
				return null;

			auto node = self._queue[p].head;
			self.unlink(node, p);

			auto op = node.op;
			(cast(DispatcherOperation) op)._qNode = null;
			return op;
		}
	}

    bool tryRemove(shared(DispatcherOperation) op) shared 
	in {
        assert(op !is null);
	}
	do {
        auto self = cast(PriorityQueue) this;
		auto o    = cast(DispatcherOperation) op;

		synchronized (self._m)
		{
			if (o._qNode is null) 
				return false; 

			self.unlink(o._qNode, o._priority);

			o._qNode = null;                      
			return true;                          
		}
	}

    bool changePriority(shared(DispatcherOperation) op, DispatcherPriority newP) shared 
	in {
        assert(op !is null);
	}
	do {
        if (!isQueueBand(newP))
            throw new Exception("The value is not one of the dispatcher's priority bands.");

        auto self = cast(PriorityQueue) this;
		auto o    = cast(DispatcherOperation) op;

		synchronized (self._m)
		{
			if (o._qNode is null) 
				return false; 

			if (o._priority == newP) 
				return true;

			self.unlink(o._qNode, o._priority);
			o._priority = newP;     
			self.linkBack(o._qNode, newP); 
			return true;
		}
	}

	struct Node
	{
        Node* prev;
        Node* next;
        shared(DispatcherOperation) op;
	}

private:
    struct QueueList
	{
        Node* head;
        Node* tail;
	}

    void linkBack(Node* node, DispatcherPriority p)
	{
        if (_queue[p].tail is null)
		{
            _queue[p].tail = node;
            _queue[p].head = _queue[p].tail;
		}
        else
		{
            node.prev = _queue[p].tail;
            _queue[p].tail.next = node;
            _queue[p].tail = _queue[p].tail.next;
		}

        if (p > atomicLoad(_highestPriority))
            atomicStore(_highestPriority, p);
	}

    void unlink(Node* node, DispatcherPriority p)
	{
        if (node.prev !is null)
            node.prev.next = node.next;
        else if (_queue[p].head == node)
            _queue[p].head = node.next;

        if (node.next !is null)
            node.next.prev = node.prev;
        else if (_queue[p].tail == node)
		{
            _queue[p].tail = node.prev;
            if (atomicLoad(_highestPriority) == p && _queue[p].tail is null)
			{
                // find new highest priority
                auto highest = p;
                for (; highest > DispatcherPriority.inactive; highest--)
                    if (_queue[highest].tail !is null)
                        break;

                atomicStore(_highestPriority, highest);
			}
		}

        node.prev = null;
        node.next = null;
	}

    Mutex _m;
    QueueList[DispatcherPriority.send + 1] _queue;
    // Read without the mutex by highestPriority(), so every write to it is
    // atomic as well; the plain reads below are all under the mutex.
    shared DispatcherPriority _highestPriority;
    bool _closed;
}

/**
* Unit tests for PriorityQueue.
*/

version (unittest)
{
    import core.thread : Thread;
    import core.atomic : atomicOp;

    /**
	* Builds a detached operation.  The dispatcher reference stays null on
	* purpose: none of these tests call abort() or invoke(), so the queue is
	* exercised in isolation.
	*/
    private shared(DispatcherOperation) makeOp(DispatcherPriority p)
    {
        return cast(shared) new DispatcherOperation(null, delegate void() {}, p);
    }

    /// Unwraps to the mutable view so tests can read queue-owned fields.
    private DispatcherOperation raw(shared(DispatcherOperation) op)
    {
        return cast(DispatcherOperation) op;
    }

    /// Pops everything the queue is willing to hand out, in order.
    private shared(DispatcherOperation)[] drain(shared(PriorityQueue) q)
    {
        shared(DispatcherOperation)[] result;
        for (auto op = q.dequeue(); op !is null; op = q.dequeue())
            result ~= op;
        return result;
    }
}

// ---------------------------------------------------------------------------
// Empty queue
// ---------------------------------------------------------------------------

unittest
{
    auto q = new shared PriorityQueue;

    assert(q.highestPriority == DispatcherPriority.inactive);
    assert(q.dequeue() is null);
    assert(q.dequeue() is null, "dequeue on an empty queue must stay idempotent");
}

// ---------------------------------------------------------------------------
// enqueue publishes the node handle into the operation
// ---------------------------------------------------------------------------

unittest
{
    auto q  = new shared PriorityQueue;
    auto op = makeOp(DispatcherPriority.normal);

    auto node = q.enqueue(op);

    assert(node !is null);
    assert(raw(op)._qNode !is null,
           "enqueue must record the node: tryRemove and changePriority key off _qNode");
    assert(raw(op)._qNode is node, "the returned node must be the one stored in the operation");
    assert(q.highestPriority == DispatcherPriority.normal);
}

// ---------------------------------------------------------------------------
// FIFO order inside one priority band
// ---------------------------------------------------------------------------

unittest
{
    auto q = new shared PriorityQueue;

    auto a = makeOp(DispatcherPriority.normal);
    auto b = makeOp(DispatcherPriority.normal);
    auto c = makeOp(DispatcherPriority.normal);

    q.enqueue(a);
    q.enqueue(b);
    q.enqueue(c);

    auto got = drain(q);
    assert(got.length == 3);
    assert(got[0] is a && got[1] is b && got[2] is c, "same-priority work must run in post order");
}

// ---------------------------------------------------------------------------
// Higher priority wins regardless of insertion order
// ---------------------------------------------------------------------------

unittest
{
    auto q = new shared PriorityQueue;

    auto bg   = makeOp(DispatcherPriority.background);
    auto norm = makeOp(DispatcherPriority.normal);
    auto send = makeOp(DispatcherPriority.send);

    q.enqueue(bg);
    q.enqueue(norm);
    q.enqueue(send);

    auto got = drain(q);
    assert(got.length == 3);
    assert(got[0] is send && got[1] is norm && got[2] is bg);
}

// ---------------------------------------------------------------------------
// highestPriority must fall back to a lower non-empty band
//
// This is the regression test for the unlink() rescan: draining the top band
// must not hide the work still sitting underneath it.
// ---------------------------------------------------------------------------

unittest
{
    auto q = new shared PriorityQueue;

    auto bg   = makeOp(DispatcherPriority.background);
    auto norm = makeOp(DispatcherPriority.normal);

    q.enqueue(bg);
    q.enqueue(norm);
    assert(q.highestPriority == DispatcherPriority.normal);

    auto first = q.dequeue();
    assert(first is norm);
    assert(q.highestPriority == DispatcherPriority.background,
           "after the top band empties, highestPriority must drop to the next non-empty band");

    auto second = q.dequeue();
    assert(second is bg, "work in lower bands must not become unreachable");
    assert(q.highestPriority == DispatcherPriority.inactive);
    assert(q.dequeue() is null);
}

/// Same rescan, but across several gaps at once.
unittest
{
    auto q = new shared PriorityQueue;

    auto idle = makeOp(DispatcherPriority.systemIdle);
    auto bg   = makeOp(DispatcherPriority.background);
    auto send = makeOp(DispatcherPriority.send);

    q.enqueue(idle);
    q.enqueue(bg);
    q.enqueue(send);

    assert(q.dequeue() is send);
    assert(q.highestPriority == DispatcherPriority.background);
    assert(q.dequeue() is bg);
    assert(q.highestPriority == DispatcherPriority.systemIdle);
    assert(q.dequeue() is idle);
    assert(q.highestPriority == DispatcherPriority.inactive);
}

// ---------------------------------------------------------------------------
// dequeue releases the node handle
// ---------------------------------------------------------------------------

unittest
{
    auto q  = new shared PriorityQueue;
    auto op = makeOp(DispatcherPriority.normal);

    q.enqueue(op);
    auto got = q.dequeue();

    assert(got is op);
    assert(raw(op)._qNode is null,
           "dequeue must clear _qNode so a late abort() correctly reports failure");
}

// ---------------------------------------------------------------------------
// Inactive work is parked, never handed out
// ---------------------------------------------------------------------------

unittest
{
    auto q      = new shared PriorityQueue;
    auto parked = makeOp(DispatcherPriority.inactive);

    q.enqueue(parked);

    assert(q.highestPriority == DispatcherPriority.inactive);
    assert(q.dequeue() is null, "inactive operations stay queued but are never dispatched");
    assert(raw(parked)._qNode !is null, "a parked operation is still in the queue");

    // ...and it becomes reachable once promoted.
    assert(q.changePriority(parked, DispatcherPriority.normal));
    assert(q.highestPriority == DispatcherPriority.normal);
    assert(q.dequeue() is parked);
}

// ---------------------------------------------------------------------------
// tryRemove: every position in the list
// ---------------------------------------------------------------------------

unittest // only element
{
    auto q  = new shared PriorityQueue;
    auto op = makeOp(DispatcherPriority.normal);

    q.enqueue(op);
    assert(q.tryRemove(op));
    assert(raw(op)._qNode is null);
    assert(q.highestPriority == DispatcherPriority.inactive);
    assert(q.dequeue() is null);
}

unittest // head, middle, tail
{
    static void check(size_t victim)
    {
        auto q = new shared PriorityQueue;
        shared(DispatcherOperation)[3] ops;
        foreach (i; 0 .. 3)
        {
            ops[i] = makeOp(DispatcherPriority.normal);
            q.enqueue(ops[i]);
        }

        assert(q.tryRemove(ops[victim]));
        assert(raw(ops[victim])._qNode is null);

        auto got = drain(q);
        assert(got.length == 2, "removing one node must not disturb its neighbours");
        foreach (op; got)
            assert(op !is ops[victim]);
    }

    check(0); // head
    check(1); // middle
    check(2); // tail
}

unittest // removing the tail keeps the list append-able
{
    auto q = new shared PriorityQueue;
    auto a = makeOp(DispatcherPriority.normal);
    auto b = makeOp(DispatcherPriority.normal);

    q.enqueue(a);
    q.enqueue(b);
    assert(q.tryRemove(b));

    auto c = makeOp(DispatcherPriority.normal);
    q.enqueue(c);

    auto got = drain(q);
    assert(got.length == 2 && got[0] is a && got[1] is c,
           "the tail pointer must survive removal of the last node");
}

// ---------------------------------------------------------------------------
// tryRemove is the arbiter: it succeeds exactly once
// ---------------------------------------------------------------------------

unittest
{
    auto q  = new shared PriorityQueue;
    auto op = makeOp(DispatcherPriority.normal);

    q.enqueue(op);
    assert(q.tryRemove(op), "first claim wins");
    assert(!q.tryRemove(op), "second claim must fail: only one caller may abort the operation");
}

unittest
{
    auto q  = new shared PriorityQueue;
    auto op = makeOp(DispatcherPriority.normal);

    q.enqueue(op);
    q.dequeue();
    assert(!q.tryRemove(op),
           "once the pump has taken the operation, abort() must report that it lost the race");
}

unittest
{
    auto q  = new shared PriorityQueue;
    auto op = makeOp(DispatcherPriority.normal); // never enqueued

    assert(!q.tryRemove(op));
}

// ---------------------------------------------------------------------------
// changePriority
// ---------------------------------------------------------------------------

unittest // promotion reorders the queue
{
    auto q = new shared PriorityQueue;

    auto bg   = makeOp(DispatcherPriority.background);
    auto norm = makeOp(DispatcherPriority.normal);

    q.enqueue(bg);
    q.enqueue(norm);

    assert(q.changePriority(bg, DispatcherPriority.send));
    assert(raw(bg)._priority == DispatcherPriority.send, "the queue owns _priority and must update it");
    assert(q.highestPriority == DispatcherPriority.send);

    auto got = drain(q);
    assert(got[0] is bg && got[1] is norm);
}

unittest // demotion reorders the queue
{
    auto q = new shared PriorityQueue;

    auto a = makeOp(DispatcherPriority.send);
    auto b = makeOp(DispatcherPriority.normal);

    q.enqueue(a);
    q.enqueue(b);

    assert(q.changePriority(a, DispatcherPriority.background));
    assert(q.highestPriority == DispatcherPriority.normal);

    auto got = drain(q);
    assert(got[0] is b && got[1] is a);
}

unittest // the node is reused, not reallocated
{
    auto q  = new shared PriorityQueue;
    auto op = makeOp(DispatcherPriority.normal);

    q.enqueue(op);
    auto before = raw(op)._qNode;

    assert(q.changePriority(op, DispatcherPriority.background));
    assert(raw(op)._qNode is before, "changePriority relinks the existing node");
    assert(raw(op)._qNode !is null);
}

unittest // moved operations land at the tail of the target band
{
    auto q = new shared PriorityQueue;

    auto first  = makeOp(DispatcherPriority.normal);
    auto second = makeOp(DispatcherPriority.normal);
    auto mover  = makeOp(DispatcherPriority.background);

    q.enqueue(first);
    q.enqueue(second);
    q.enqueue(mover);

    assert(q.changePriority(mover, DispatcherPriority.normal));

    auto got = drain(q);
    assert(got.length == 3);
    assert(got[0] is first && got[1] is second && got[2] is mover,
           "a promoted operation must not jump ahead of work already waiting in that band");
}

unittest // no-op and failure cases
{
    auto q  = new shared PriorityQueue;
    auto op = makeOp(DispatcherPriority.normal);

    q.enqueue(op);
    assert(q.changePriority(op, DispatcherPriority.normal), "same priority is a successful no-op");
    assert(raw(op)._priority == DispatcherPriority.normal);
    assert(q.dequeue() is op);

    assert(!q.changePriority(op, DispatcherPriority.send),
           "an operation that already left the queue cannot be reprioritised");

    auto never = makeOp(DispatcherPriority.normal);
    assert(!q.changePriority(never, DispatcherPriority.send));
}

unittest // emptying a band via changePriority also rescans highestPriority
{
    auto q = new shared PriorityQueue;

    auto top = makeOp(DispatcherPriority.send);
    auto low = makeOp(DispatcherPriority.background);

    q.enqueue(top);
    q.enqueue(low);
    assert(q.highestPriority == DispatcherPriority.send);

    assert(q.changePriority(top, DispatcherPriority.systemIdle));
    assert(q.highestPriority == DispatcherPriority.background,
           "vacating the top band through changePriority must trigger the same rescan as unlink");
}

// ---------------------------------------------------------------------------
// Mixed workload
// ---------------------------------------------------------------------------

unittest
{
    auto q = new shared PriorityQueue;

    // Two operations in each band from systemIdle up to send.
    shared(DispatcherOperation)[] all;
    for (int p = DispatcherPriority.systemIdle; p <= DispatcherPriority.send; ++p)
        foreach (_; 0 .. 2)
        {
            auto op = makeOp(cast(DispatcherPriority) p);
            all ~= op;
            q.enqueue(op);
        }

    auto got = drain(q);
    assert(got.length == all.length, "nothing may be lost while walking down the bands");

    // Priorities must come out non-increasing.
    foreach (i; 1 .. got.length)
        assert(raw(got[i - 1])._priority >= raw(got[i])._priority);
}

// ---------------------------------------------------------------------------
// Concurrency: producers vs. the pump
// ---------------------------------------------------------------------------

unittest
{
    enum producers = 4;
    enum perThread = 250;

    auto q = new shared PriorityQueue;

    Thread[] threads;
    foreach (t; 0 .. producers)
    {
        threads ~= new Thread({
            foreach (i; 0 .. perThread)
                q.enqueue(makeOp(cast(DispatcherPriority)
								 (DispatcherPriority.systemIdle + (i % 5))));
        }).start();
    }
    foreach (t; threads)
        t.join();

    assert(drain(q).length == producers * perThread,
           "concurrent enqueues must neither lose nor duplicate operations");
}

/**
* The ownership invariant: an operation is claimed by exactly one of
* dequeue() (the pump) or tryRemove() (an aborter), never both, never neither.
*/
unittest
{
    enum count = 500;

    auto q = new shared PriorityQueue;
    shared(DispatcherOperation)[] ops;

    foreach (i; 0 .. count)
    {
        auto op = makeOp(DispatcherPriority.normal);
        ops ~= op;
        q.enqueue(op);
    }

    shared size_t dequeued;
    shared size_t removed;

    auto pump = new Thread({
        while (q.dequeue() !is null)
            atomicOp!"+="(dequeued, 1);
    }).start();

    auto aborter = new Thread({
        foreach (op; ops)
            if (q.tryRemove(op))
                atomicOp!"+="(removed, 1);
    }).start();

    pump.join();
    aborter.join();

    // The pump may exit early on a transiently empty queue, so sweep the rest.
    while (q.dequeue() !is null)
        atomicOp!"+="(dequeued, 1);

    assert(dequeued + removed == count,
           "every operation must be claimed exactly once by either the pump or the aborter");

    foreach (op; ops)
        assert(raw(op)._qNode is null, "no operation may still reference a freed node");
}

/**
 * A delegate type for handling DispatcherOperation events.
 */
alias DispatcherOperationEventHandler = void delegate(shared(DispatcherOperation) op);

/**
 * A delegate type for reporting an exception that escaped a dispatcher
 * operation and that nothing else is going to observe.
 */
alias DispatcherUnhandledExceptionHandler =
    void delegate(shared(DispatcherOperation) op, Exception exception);

/**
 * class DispatcherOperation represents a delegate that has been
 * posted to the Dispatcher queue.
 */
class DispatcherOperation
{
    this(shared(Dispatcher) dispatcher,
         void delegate() work,
		 DispatcherPriority priority,
		 bool awaited = false)
	{
        _dispatcher = dispatcher;
        _work = work;
        _priority = priority;
        _awaited = awaited;
        _status = OperationStatus.pending;
        _m = new Mutex(); 
		_done = new Condition(_m);
	}

    @property shared(Dispatcher) dispatcher() shared pure nothrow @nogc
    {
        return _dispatcher;
    }

    @property void priority(DispatcherPriority value) shared
	{
        _dispatcher._queue.changePriority(this, value);
	}
    
    @property DispatcherPriority priority() shared const nothrow @nogc
    {
        return _priority;
    }

    @property OperationStatus status() shared
    {
        return atomicLoad(_status);
    }

    @property Exception exception() shared
    {
        return cast(Exception) _exception;
    }

    @event EventAccessor!(DispatcherOperationEventHandler) onCompleted() shared
	{
        return EventAccessor!(DispatcherOperationEventHandler)
		(
            // add handler                                                    
            (DispatcherOperationEventHandler h) => addHandler((cast(DispatcherOperation) this)._onCompleted, OperationStatus.completed, h),
            // remove handler
            (DispatcherOperationEventHandler h) => removeHandler((cast(DispatcherOperation) this)._onCompleted, h)  
		);
	}

    @event EventAccessor!(DispatcherOperationEventHandler) onAborted() shared
	{
        return EventAccessor!(DispatcherOperationEventHandler)
		(
            // add handler                                                    
            (DispatcherOperationEventHandler h) => addHandler((cast(DispatcherOperation) this)._onAborted, OperationStatus.aborted, h),
            // remove handler
            (DispatcherOperationEventHandler h) => removeHandler((cast(DispatcherOperation) this)._onAborted, h)  
		);
	}

    OperationStatus wait() shared
	{
        synchronized (_m) 
		{
            while (atomicLoad(_status) != OperationStatus.completed &&
                   atomicLoad(_status) != OperationStatus.aborted)
			{
                _done.wait();
			}

            return atomicLoad(_status);
        }
    }

    bool abort() shared
	{
        // Try to remove this operation from queue
		if (!_dispatcher._queue.tryRemove(this))
			return false; // the queue decides who owns the operation
        setAborted();     // ...and only the winner performs the transition
        return true;
	}

protected:
    void setAborted() shared
	{
		auto self = cast(DispatcherOperation) this;
		Multicast!DispatcherOperationEventHandler evtAborted;

		synchronized (self._m)
		{
			if (atomicLoad(self._status) != OperationStatus.pending)
				return;

			atomicStore(self._status, OperationStatus.aborted);
			evtAborted = self._onAborted.dup;
			self._done.notifyAll();
		}

		evtAborted(this);
	}

	void invoke() shared
	{
        auto self = cast(DispatcherOperation) this;

        synchronized (self._m) 
		{ 
			atomicStore(self._status, OperationStatus.executing); 
		}

        Multicast!DispatcherOperationEventHandler evt;
        Exception failure;

		try 
		{
			self._work();
			synchronized (self._m) 
			{ 
				atomicStore(self._status, OperationStatus.completed); 
                evt = self._onCompleted.dup;
				self._done.notifyAll(); 
			}
		} 
		catch (Exception e) 
		{
			failure = e;
			synchronized (self._m) 
			{ 
				self._exception = e; 
				atomicStore(self._status, OperationStatus.aborted); 
                evt = self._onAborted.dup;
				self._done.notifyAll(); 
			}
		}
		catch (Throwable t)
		{
			// An Error says the program is already in an undefined state, so it
			// is rethrown rather than recorded and swallowed the way an
			// Exception is.  The waiters still have to be released on the way
			// out: a thread blocked in wait() would otherwise stay there for
			// good while the Error unwinds past it.  Handlers are deliberately
			// not run -- calling user code while an Error propagates can only
			// make matters worse.
			synchronized (self._m)
			{
				atomicStore(self._status, OperationStatus.aborted);
				self._done.notifyAll();
			}

			throw t;
		}

        evt(this);

        // An awaited operation delivers its exception to the caller of
        // invoke(), so it is handled by definition.  Only work nobody is
        // waiting for would otherwise fail in complete silence.
        if (failure !is null && !_awaited)
            _dispatcher.raiseUnhandledException(this, failure);
	}
    
    ///
    /// These fields are protected by the PriorityQueue mutex 
	/// and should not be modified within this class.
    DispatcherPriority _priority;
    PriorityQueue.Node* _qNode;

private:
    void addHandler(ref Multicast!DispatcherOperationEventHandler ev,
                    OperationStatus trigger,
                    DispatcherOperationEventHandler h) shared
	{
		auto self = cast(DispatcherOperation) this;
		bool fireNow;

		synchronized (self._m) 
		{
			if (atomicLoad(self._status) == trigger) 
                // If it's too late - call immediately
				fireNow = true; 

			else ev.add(h);                                            
		}

		if (fireNow) 
			h(this);         
	}

    void removeHandler(ref Multicast!DispatcherOperationEventHandler ev,
                       DispatcherOperationEventHandler h) shared
	{
	    auto self = cast(DispatcherOperation) this;
	    synchronized (self._m) 
		{ 
			ev.remove(h); 
		}
	}

    shared(Dispatcher) _dispatcher;
    OperationStatus _status;
    // Set at construction, never afterwards: a caller blocked in wait() can
    // only be recorded before the work runs, or the operation might fail
    // before the flag is set.
    bool _awaited;
    void delegate() _work;
    Exception _exception;
    Mutex _m;
    Condition _done;
    Multicast!DispatcherOperationEventHandler _onCompleted;
    Multicast!DispatcherOperationEventHandler _onAborted;
}

/**
 * Unit tests for DispatcherOperation and for the dispatcher's scheduling
 * policy (foreground vs. deferred background work).
 */

version (unittest)
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import core.time : MonoTime, msecs;

    /**
	* Runs body with a dispatcher driven by the supplied loop, releasing the
	* thread-local slot afterwards whatever happens.
	*/
    private void withDispatcher(EventLoop loop, scope void delegate(shared(Dispatcher)) body)
    {
        auto d = cast(shared) new Dispatcher(loop);
        scope (exit) d.shutdown();
        body(d);
    }

    /// Convenience overload for the common ManualEventLoop case.
    private void withDispatcher(scope void delegate(shared(Dispatcher), ManualEventLoop) body)
    {
        auto loop = new ManualEventLoop;
        withDispatcher(loop, (shared(Dispatcher) d) { body(d, loop); });
    }

    /// Pumps the loop on this thread until something calls shutdown.
    private void pump(shared(Dispatcher) d)
    {
        (cast(Dispatcher) d).run();
    }

    /**
	* Drains everything currently queued, then stops.  The sentinel sits at
	* the lowest dispatchable band, so it runs only once all real work is
	* done.  Valid only while isInputPending is false.
	*/
    private void pumpUntilIdle(shared(Dispatcher) d)
    {
        d.invokeAsync({ d.shutdown(); }, DispatcherPriority.systemIdle);
        pump(d);
    }
}

// ===========================================================================
// DispatcherOperation: status lifecycle
// ===========================================================================

unittest
{
    withDispatcher((d, loop) {
        shared(DispatcherOperation) op;
        OperationStatus seenFromInside;

        op = d.invokeAsync({ seenFromInside = op.status; });

        assert(op.status == OperationStatus.pending, "queued work starts out pending");

        pumpUntilIdle(d);

        assert(seenFromInside == OperationStatus.executing,
               "the operation must report executing while its delegate runs");
        assert(op.status == OperationStatus.completed);
    });
}

// ===========================================================================
// DispatcherOperation: abort
// ===========================================================================

unittest // aborting queued work wins the race and suppresses execution
{
    withDispatcher((d, loop) {
        bool ran;
        auto op = d.invokeAsync({ ran = true; });

        assert(op.abort(), "the pump has not claimed it yet, so abort must succeed");
        assert(op.status == OperationStatus.aborted);
        assert(!op.abort(), "a second abort must report that it lost the race");

        pumpUntilIdle(d);
        assert(!ran, "an aborted operation must never execute");
    });
}

unittest // aborting after completion fails
{
    withDispatcher((d, loop) {
        auto op = d.invokeAsync({ });
        pumpUntilIdle(d);

        assert(op.status == OperationStatus.completed);
        assert(!op.abort(), "a completed operation can no longer be aborted");
        assert(op.status == OperationStatus.completed, "a failed abort must not rewrite the status");
    });
}

unittest // aborting from inside its own execution fails
{
    withDispatcher((d, loop) {
        shared(DispatcherOperation) op;
        bool abortSucceeded = true;

        op = d.invokeAsync({ abortSucceeded = op.abort(); });
        pumpUntilIdle(d);

        assert(!abortSucceeded,
               "once the pump dequeued the operation, abort must report failure");
    });
}

// ===========================================================================
// DispatcherOperation: exceptions
// ===========================================================================

unittest
{
    withDispatcher((d, loop) {
        auto op = d.invokeAsync({ throw new Exception("boom"); });

        pumpUntilIdle(d);   // the throw must not escape the pump

        assert(op.status == OperationStatus.aborted);
        assert(op.exception !is null, "the failure must be captured on the operation");
        assert(op.exception.msg == "boom");
    });
}

unittest // a failing operation must not stop the pump
{
    withDispatcher((d, loop) {
        bool laterRan;
        d.invokeAsync({ throw new Exception("boom"); });
        d.invokeAsync({ laterRan = true; });

        pumpUntilIdle(d);
        assert(laterRan, "work queued behind a failing operation must still run");
    });
}

// ===========================================================================
// DispatcherOperation: events
// ===========================================================================

unittest // onCompleted fires exactly once, with the operation as argument
{
    withDispatcher((d, loop) {
        int fired;
        shared(DispatcherOperation) argument;

        auto op = d.invokeAsync({ });
        op.onCompleted ~= (o) { fired++; argument = o; };

        pumpUntilIdle(d);

        assert(fired == 1);
        assert(argument is op);
    });
}

unittest // late subscription must not silently lose the notification
{
    withDispatcher((d, loop) {
        auto op = d.invokeAsync({ });
        pumpUntilIdle(d);
        assert(op.status == OperationStatus.completed);

        bool fired;
        op.onCompleted ~= (o) { fired = true; };

        assert(fired, "subscribing after completion must invoke the handler immediately");
    });
}

unittest // same guarantee on the abort side
{
    withDispatcher((d, loop) {
        auto op = d.invokeAsync({ });
        assert(op.abort());

        bool fired;
        op.onAborted ~= (o) { fired = true; };

        assert(fired, "subscribing after an abort must invoke the handler immediately");
    });
}

unittest // onAborted fires for an explicit abort and for a failure
{
    withDispatcher((d, loop) {
        int abortedFires;

        auto cancelled = d.invokeAsync({ });
        cancelled.onAborted ~= (o) { abortedFires++; };
        assert(cancelled.abort());
        assert(abortedFires == 1);

        auto failed = d.invokeAsync({ throw new Exception("boom"); });
        failed.onAborted ~= (o) { abortedFires++; };
        pumpUntilIdle(d);

        assert(abortedFires == 2,
               "a failing operation reports through onAborted as well -- "
               ~ "subscribers tell the two apart by inspecting exception");
    });
}

unittest // the wrong event must stay silent
{
    withDispatcher((d, loop) {
        bool completedFired;
        auto op = d.invokeAsync({ });
        op.onCompleted ~= (o) { completedFired = true; };

        assert(op.abort());
        pumpUntilIdle(d);

        assert(!completedFired, "an aborted operation must not raise onCompleted");
    });
}

unittest // a removed handler stops being called
{
    withDispatcher((d, loop) {
        bool fired;
        void handler(shared(DispatcherOperation) o) { fired = true; }

        auto op = d.invokeAsync({ });
        op.onCompleted ~= &handler;
        op.onCompleted -= &handler;

        pumpUntilIdle(d);
        assert(!fired);
    });
}

// ===========================================================================
// DispatcherOperation: wait
// ===========================================================================

unittest // a waiter on another thread wakes when the work completes
{
    withDispatcher((d, loop) {
        auto op = d.invokeAsync({ });

        shared int observed = -1;
        auto waiter = new Thread({ atomicStore(observed, cast(int) op.wait()); }).start();

        pumpUntilIdle(d);
        waiter.join();

        assert(atomicLoad(observed) == cast(int) OperationStatus.completed);
    });
}

unittest // a waiter also wakes on abort
{
    withDispatcher((d, loop) {
        auto op = d.invokeAsync({ });

        shared int observed = -1;
        auto waiter = new Thread({ atomicStore(observed, cast(int) op.wait()); }).start();

        // Give the waiter a moment to actually block, then cancel it.
        Thread.sleep(20.msecs);
        assert(op.abort());
        waiter.join();

        assert(atomicLoad(observed) == cast(int) OperationStatus.aborted);
    });
}

unittest // no lost wakeup: waiting on already-finished work returns at once
{
    withDispatcher((d, loop) {
        auto op = d.invokeAsync({ });
        pumpUntilIdle(d);
        assert(op.status == OperationStatus.completed);

        // A lost wakeup shows up as this join() never returning.
        shared bool returned;
        auto waiter = new Thread({ op.wait(); atomicStore(returned, true); }).start();
        waiter.join();

        assert(atomicLoad(returned));
    });
}

// ===========================================================================
// Scheduling policy: background work is held back while input is pending
// ===========================================================================

unittest // foreground runs, background is deferred
{
    withDispatcher((d, loop) {
        loop.inputPending = true;

        bool backgroundRan, foregroundRan;
        d.invokeAsync({ backgroundRan = true; }, DispatcherPriority.background);
        d.invokeAsync({ foregroundRan = true; d.shutdown(); }, DispatcherPriority.send);

        pump(d);

        assert(foregroundRan, "foreground work ignores pending input");
        assert(!backgroundRan, "background work waits while the user is interacting");
    });
}

unittest // with no input pending, background runs straight away
{
    withDispatcher((d, loop) {
        loop.inputPending = false;

        bool ran;
        d.invokeAsync({ ran = true; d.shutdown(); }, DispatcherPriority.background);
        pump(d);

        assert(ran);
    });
}

unittest // the starvation guard promotes deferred work after the delay
{
    withDispatcher((d, loop) {
        loop.inputPending = true;   // never drains: only the deadline can save this op

        bool ran;
        auto start = MonoTime.currTime;
        d.invokeAsync({ ran = true; d.shutdown(); }, DispatcherPriority.background);

        pump(d);
        auto elapsed = MonoTime.currTime - start;

        assert(ran, "background work must not starve behind permanently pending input");
        assert(elapsed >= 40.msecs,
               "...but it must be held back for roughly the promotion delay first");
    });
}

unittest // every idle band is deferred, not just background
{
    withDispatcher((d, loop) {
        loop.inputPending = true;

        bool idleRan;
        d.invokeAsync({ idleRan = true; }, DispatcherPriority.systemIdle);
        d.invokeAsync({ d.shutdown(); }, DispatcherPriority.input);

        pump(d);
        assert(!idleRan, "input priority and above are foreground; systemIdle is not");
    });
}

unittest // draining the queue disarms it again
{
    withDispatcher((d, loop) {
        loop.inputPending = false;
        d.invokeAsync({ }, DispatcherPriority.background);
        d.invokeAsync({ d.shutdown(); }, DispatcherPriority.systemIdle);

        pump(d);
        assert(!(cast(Dispatcher) d).backgroundDeferralArmed,
               "an empty queue must reset the deadline so the next item gets a fresh delay");
    });
}

// ===========================================================================
// Dispatcher: queueing semantics
// ===========================================================================

unittest // invokeAsync from the dispatcher thread never runs inline
{
    withDispatcher((d, loop) {
        bool innerRan;
        bool innerRanBeforeReturn;

        d.invokeAsync({
            d.invokeAsync({ innerRan = true; });
            innerRanBeforeReturn = innerRan;
        });

        pumpUntilIdle(d);

        assert(!innerRanBeforeReturn, "nested posts must not execute inline");
        assert(innerRan, "...but they must still execute later");
    });
}

unittest // priority order end to end
{
    withDispatcher((d, loop) {
        int[] order;
        d.invokeAsync({ order ~= 4; }, DispatcherPriority.background);
        d.invokeAsync({ order ~= 2; }, DispatcherPriority.normal);
        d.invokeAsync({ order ~= 1; }, DispatcherPriority.send);
        d.invokeAsync({ order ~= 3; }, DispatcherPriority.input);

        pumpUntilIdle(d);
        assert(order == [1, 2, 3, 4]);
    });
}

unittest // inactive work is never dispatched
{
    withDispatcher((d, loop) {
        bool ran;
        auto op = d.invokeAsync({ ran = true; }, DispatcherPriority.inactive);

        pumpUntilIdle(d);

        assert(!ran, "inactive operations are queued but never dispatched");
        assert(op.status == OperationStatus.aborted,
               "...and shutdown must still release them: dequeue() skips the"
               ~ " inactive band, so nothing else ever would");
    });
}

unittest // promoting through the operation's setter makes it reachable
{
    withDispatcher((d, loop) {
        bool ran;
        auto op = d.invokeAsync({ ran = true; }, DispatcherPriority.inactive);

        // Promoted from inside the pump, by work that runs before it.
        d.invokeAsync({ op.priority = DispatcherPriority.normal; },
                      DispatcherPriority.send);
        d.invokeAsync({ d.shutdown(); }, DispatcherPriority.systemIdle);

        pump(d);

        assert(op.priority == DispatcherPriority.normal);
        assert(ran, "a promoted operation becomes reachable to the pump");
    });
}

unittest // shutdown drops whatever is still queued
{
    withDispatcher((d, loop) {
        bool ran;
        d.invokeAsync({ d.shutdown(); }, DispatcherPriority.send);
        auto stranded = d.invokeAsync({ ran = true; }, DispatcherPriority.normal);

        pump(d);

        assert(!ran, "work still queued when the loop exits is dropped");
        assert(stranded.status == OperationStatus.aborted,
               "...and must reach a terminal status so waiters are released");
    });
}

unittest // a cross-thread waiter is released by shutdown
{
    withDispatcher((d, loop) {
        shared int observed = -1;
        auto stranded = d.invokeAsync({ }, DispatcherPriority.normal);

        auto waiter = new Thread({
            atomicStore(observed, cast(int) stranded.wait());
        }).start();

        Thread.sleep(20.msecs);          // let the waiter block
        d.invokeAsync({ d.shutdown(); }, DispatcherPriority.send);
        pump(d);
        waiter.join();                   // hangs forever if shutdown leaves it pending

        assert(atomicLoad(observed) == cast(int) OperationStatus.aborted);
    });
}

unittest // only the owning thread may pump
{
    import std.exception : assertThrown;

    withDispatcher((d, loop) {
        shared bool threw;

        auto intruder = new Thread({
            try
                (cast(Dispatcher) d).run();
            catch (Exception)
                atomicStore(threw, true);
        }).start();

        intruder.join();
        assert(atomicLoad(threw), "run() from a foreign thread must fail verifyAccess");
    });
}

/**
 * Dispatcher owns a thread's work queue and message loop.
 *
 * A dispatcher is bound to the thread that created it: checkAccess and
 * verifyAccess implement thread affinity, invokeAsync/invoke marshal work
 * onto the dispatcher thread from anywhere, and run pumps the underlying
 * platform EventLoop until shutdown.
 *
 * All queueing and scheduling live here, platform-independently; the only
 * platform-specific piece is the EventLoop supplied at construction.
 */
final class Dispatcher : DispatcherObject
{
   /**
    * The dispatcher of the calling thread, created on first use with the
    * platform's native event loop.
    */
    static @property shared(Dispatcher) current()
    {
        if (t_current is null)
            t_current = new Dispatcher(createPlatformEventLoop());

        return cast(shared) t_current;
    }

   /**
    * The dispatcher of the calling thread, or null when it has none.
    * Unlike current, this never creates one.
    */
    static @property shared(Dispatcher) currentOrNull()
    {
        return cast(shared) t_current;
    }

    @disable this();  // no default constructor: must supply an event loop

   /**
    * Creates a dispatcher owned by the calling thread, driven by the given
    * event loop.  A thread can host at most one dispatcher at a time.
    */
    this(EventLoop loop)
    in {
        assert(loop !is null);
    }
    do {
        if (t_current !is null)
            throw new Exception("This thread already has a dispatcher.");

        super(cast(shared) this);
        _threadId = Thread.getThis().id;
        _loop = loop;
        _queue = new shared PriorityQueue;
        _eventMutex = new Mutex;
        t_current = this;
    }

   /**
    * The thread this dispatcher is bound to.
    */
    @property uint threadId() pure const shared nothrow @nogc
    {
        return _threadId;
    } 

    version (unittest)
	{
		/// Test hook: whether background work is currently being held back.
		/// Owner-thread only, like the deadline it inspects.
		@property bool backgroundDeferralArmed() const pure nothrow @nogc
		{
			return _backgroundDeadline != MonoTime.zero;
		}
	}

   /**
    * Raised on the dispatcher thread when an operation nobody awaits fails.
    *
    * Work posted through invokeAsync has no caller to receive its exception,
    * so without a subscriber here such a failure is recorded on the
    * operation and never seen again.  Operations awaited through invoke()
    * are excluded: their exception is rethrown to the calling thread.
    *
    * The pump keeps running either way; an exception thrown by a handler is
    * swallowed rather than allowed to recurse into this hook.
    */
    @event @property auto onUnhandledException() shared
    {
        auto self = cast(Dispatcher) this;

        return EventAccessor!DispatcherUnhandledExceptionHandler(
            (DispatcherUnhandledExceptionHandler h)
            {
                synchronized (self._eventMutex)
                    self._onUnhandledException.add(h);
            },
            (DispatcherUnhandledExceptionHandler h)
            {
                synchronized (self._eventMutex)
                    self._onUnhandledException.remove(h);
            });
    }

   /**
    * Thread-safe: queues work to run asynchronously on the dispatcher
    * thread.  Work queued from the dispatcher thread itself still runs
    * later, never inline.
    */
    shared(DispatcherOperation) invokeAsync(void delegate() work, DispatcherPriority priority = DispatcherPriority.normal) shared
    in {
        assert(work !is null);
    }
    do {
        return post(work, priority, false);
    }

   /**
    * Runs work on the dispatcher thread synchronously: inline when called
    * on the dispatcher thread, otherwise queued and awaited.  An exception
    * thrown by the work is rethrown on the calling thread.
    */
    void invoke(void delegate() work, DispatcherPriority priority = DispatcherPriority.normal) shared
    in {
        assert(work !is null);
    }
    do {
        // Checked before the inline path too, so the same call is rejected
        // wherever it comes from: from another thread it would block its
        // caller forever on a band the pump never dispatches.
        if (priority <= DispatcherPriority.inactive)
            throw new Exception("invoke() cannot wait at a priority that is never dispatched.");

        if (checkAccess())
        {
            work();
            return;
        }

        // Posted as awaited, so its failure is not reported as unhandled:
        // it is rethrown below instead.
        auto op = post(work, priority, true);
        op.wait();

        if (op.status == OperationStatus.aborted)
		{
            if (op.exception !is null)
                throw op.exception;
            else
                throw new Exception("The operation was aborted.");
		}
    }

   /**
    * Pumps the event loop on the dispatcher thread until shutdown is
    * called.  Queued work is drained in FIFO order on every wake-up.
    */
    void run()
    {
        verifyAccess();

        _loop.run(&processQueue);

        // Nobody will ever run this work now; releasing it wakes any thread
		// blocked in wait() instead of leaving it stuck forever.  Harmless when
		// shutdown() already did it: close() is idempotent.
		foreach (op; _queue.close())
			op.setAborted();

        if (t_current is this)
            t_current = null;
    }

   /**
    * Thread-safe: stops the event loop.  Work still queued when the loop
    * exits is dropped, and later invokeAsync calls throw.
    */
    void shutdown() shared
    {
        atomicStore(_shutdownRequested, true);

        // Release whatever is still queued right here rather than only on
        // the way out of run(): shutting down a dispatcher that was never
        // pumped would otherwise leave its operations pending forever, and
        // anyone blocked in wait() along with them.
        foreach (op; _queue.close())
            op.setAborted();

        _loop.quit();

        if (Thread.getThis().id == _threadId && (cast(shared) t_current) is this)
            t_current = null;
    }

package:
   /*
    * Reports a failure that nothing else will observe.  Called by the
    * operation itself, on the dispatcher thread.
    */
    void raiseUnhandledException(shared(DispatcherOperation) op, Exception exception) shared
    {
        auto self = cast(Dispatcher) this;
        Multicast!DispatcherUnhandledExceptionHandler handlers;

        // Snapshot under the lock, deliver outside it.
        synchronized (self._eventMutex)
            handlers = self._onUnhandledException.dup;

        try
            handlers(op, exception);
        catch (Exception)
        {
            // A reporting handler that fails must not take down the pump,
            // and must not come back through this hook.
        }
    }

private:
   /*
    * The one path onto the queue; awaited marks operations whose exception
    * a caller of invoke() is going to receive.
    */
    shared(DispatcherOperation) post(void delegate() work, DispatcherPriority priority, bool awaited) shared
    {
        if (!isQueueBand(priority))
            throw new Exception("The value is not one of the dispatcher's priority bands.");

        auto op = cast(shared) new DispatcherOperation(this, work, priority, awaited);

        // The queue itself rejects the operation once it has been closed.
        // Testing a separate flag first would leave a window in which
        // shutdown drains the queue between the check and the enqueue,
        // stranding the operation -- and any thread waiting on it.
        if (_queue.enqueue(op) is null)
            throw new Exception("The dispatcher has been shut down.");

        _loop.requestWake();
        return op;
    }

    bool isForeground(DispatcherPriority p)
	{
        return (p >= DispatcherPriority.input && p <= DispatcherPriority.send);
	}

    void processQueue()
	{
		while (!atomicLoad(_shutdownRequested))
		{
			DispatcherPriority p;
			if ((p = _queue.highestPriority) <= DispatcherPriority.inactive) 
			{ 
				_backgroundDeadline = MonoTime.zero; 
				return; 
			}

			bool deadlineSet = _backgroundDeadline != MonoTime.zero;
			bool promoted = deadlineSet && MonoTime.currTime >= _backgroundDeadline;
			bool runNow = isForeground(p)
				|| !_loop.isInputPending()
				|| promoted;

			if (!runNow) 
			{
				if (!deadlineSet) 
					_backgroundDeadline = MonoTime.currTime + BACKGROUND_PROMOTION_DELAY;

				// Wake when the deadline is actually due rather than a full delay
				// later: it may have been armed several wakes ago.
				_loop.requestWakeAfter(_backgroundDeadline - MonoTime.currTime);
				return;
			}

			auto op = _queue.dequeue();
			if (op is null) 
				continue;

			// Disarm a guard that has just fired, so the next deferred item
			// serves a fresh delay of its own.  Leaving it armed would let the
			// whole backlog through in one burst on the first promotion --
			// exactly the input starvation the delay exists to prevent.
			if (promoted)
				_backgroundDeadline = MonoTime.zero;

			op.invoke();
		}
	}

    enum Duration BACKGROUND_PROMOTION_DELAY = dur!"msecs"(50);

    static Dispatcher t_current;   // thread-local: one dispatcher per thread

    immutable uint    _threadId;
    EventLoop         _loop;
    MonoTime          _backgroundDeadline;
    shared bool       _shutdownRequested;
    Mutex             _eventMutex;
    Multicast!DispatcherUnhandledExceptionHandler _onUnhandledException;

protected:
    shared(PriorityQueue) _queue;
}

/**
 * Unit tests for Dispatcher
 */

// ---------------------------------------------------------------------------
// Thread affinity, one-per-thread, inline invoke
// ---------------------------------------------------------------------------

unittest
{
    import std.exception : assertThrown;

    withDispatcher((d, loop) {
        assert(Dispatcher.current is d);
        assert(d.threadId == Thread.getThis().id);
        assert(d.checkAccess());
        d.verifyAccess();

        // A thread hosts at most one dispatcher.
        assertThrown(new Dispatcher(new ManualEventLoop));

        // invoke on the owning thread runs inline, with no pump running.
        int calls;
        d.invoke({ calls++; });
        assert(calls == 1);
    });
}

// ---------------------------------------------------------------------------
// FIFO processing, shutdown from inside a work item, rejection afterwards
// ---------------------------------------------------------------------------

unittest
{
    import std.exception : assertThrown;

    withDispatcher((d, loop) {
        int[] order;
        d.invokeAsync({ order ~= 1; });
        d.invokeAsync({ order ~= 2; });
        d.invokeAsync({ order ~= 3; d.shutdown(); });

        pump(d);

        assert(order == [1, 2, 3], "same-priority work runs in post order");
        assertThrown(d.invokeAsync({ }), "posting after shutdown must be rejected");
    });
}

// ---------------------------------------------------------------------------
// Cross-thread marshaling over the portable loop
// ---------------------------------------------------------------------------

unittest
{
    withDispatcher((d, loop) {
        auto owner = Thread.getThis();

        // Written on one thread and read on another, so they are atomic here
        // rather than plain bools.
        shared bool ranOnOwnerThread;
        shared bool invokeRan;
        shared bool accessDenied;
        shared bool exceptionMarshaled;

        auto worker = new Thread({
            scope (exit) d.shutdown();

            d.invokeAsync({
                atomicStore(ranOnOwnerThread, Thread.getThis() is owner);
            });

            d.invoke({ atomicStore(invokeRan, true); });

            // A foreign thread is denied access.
            assert(!d.checkAccess());
            try
                d.verifyAccess();
            catch (Exception)
                atomicStore(accessDenied, true);

            // A failure inside the work item surfaces on the calling thread.
            try
                d.invoke({ throw new Exception("boom"); });
            catch (Exception e)
                atomicStore(exceptionMarshaled, e.msg == "boom");
        }).start();

        pump(d);
        worker.join();

        assert(atomicLoad(ranOnOwnerThread), "queued work runs on the dispatcher thread");
        assert(atomicLoad(invokeRan));
        assert(atomicLoad(accessDenied));
        assert(atomicLoad(exceptionMarshaled));
    });
}

// ---------------------------------------------------------------------------
// End-to-end over the real platform loop
// ---------------------------------------------------------------------------

unittest
{
    // Win32 on Windows, the portable fallback elsewhere -- no version() blocks.
    withDispatcher(createPlatformEventLoop(), (shared(Dispatcher) d) {
        shared int processed;

        auto worker = new Thread({
            scope (exit) d.shutdown();

            foreach (i; 0 .. 5)
                d.invokeAsync({ atomicOp!"+="(processed, 1); });

            d.invoke({ });   // FIFO barrier: all five ran before this returns
        }).start();

        pump(d);
        worker.join();

        assert(atomicLoad(processed) == 5);
    });
}
// ===========================================================================
// Dispatcher: unhandled exceptions
// ===========================================================================

unittest // a failure nobody awaits reaches the hook
{
    withDispatcher((d, loop) {
        shared(DispatcherOperation) reported;
        Exception seen;

        d.onUnhandledException ~= (shared(DispatcherOperation) op, Exception e) {
            reported = op;
            seen = e;
        };

        auto op = d.invokeAsync({ throw new Exception("boom"); });
        pumpUntilIdle(d);

        assert(seen !is null, "a fire-and-forget failure must not vanish silently");
        assert(seen.msg == "boom");
        assert(reported is op, "the report identifies which operation failed");
        assert(op.status == OperationStatus.aborted);
    });
}

unittest // an awaited failure is rethrown instead of reported
{
    withDispatcher((d, loop) {
        shared bool hookFired;
        shared bool rethrown;

        d.onUnhandledException ~= (shared(DispatcherOperation) op, Exception e) {
            atomicStore(hookFired, true);
        };

        auto worker = new Thread({
            scope (exit) d.shutdown();

            try
                d.invoke({ throw new Exception("boom"); });
            catch (Exception e)
                atomicStore(rethrown, e.msg == "boom");
        }).start();

        pump(d);
        worker.join();

        assert(atomicLoad(rethrown), "invoke() hands the exception to its caller");
        assert(!atomicLoad(hookFired), "...so it is not unhandled and must not be reported");
    });
}

unittest // a reporting handler that throws must not stop the pump
{
    withDispatcher((d, loop) {
        bool laterRan;

        d.onUnhandledException ~= (shared(DispatcherOperation) op, Exception e) {
            throw new Exception("the handler is broken too");
        };

        d.invokeAsync({ throw new Exception("boom"); });
        d.invokeAsync({ laterRan = true; });
        pumpUntilIdle(d);

        assert(laterRan, "work queued after a failed report still runs");
    });
}

unittest // a removed handler stops receiving reports
{
    withDispatcher((d, loop) {
        int reports;

        void onFailure(shared(DispatcherOperation) op, Exception e)
        {
            reports++;
        }

        d.onUnhandledException ~= &onFailure;
        d.onUnhandledException -= &onFailure;

        d.invokeAsync({ throw new Exception("boom"); });
        pumpUntilIdle(d);

        assert(reports == 0);
    });
}

unittest // an Error releases the waiters before it unwinds past them
{
    withDispatcher((d, loop) {
        shared int observed = -1;

        auto op = d.invokeAsync({ throw new Error("fatal"); });

        auto waiter = new Thread({
            atomicStore(observed, cast(int) op.wait());
        }).start();

        Thread.sleep(20.msecs);          // let the waiter block

        // Unlike an Exception, an Error is not swallowed: it unwinds out of
        // the pump.  Catching it here is what a test can do; a real program
        // would be on its way down.
        try
            pump(d);
        catch (Error)
        {
        }

        waiter.join();                   // hangs forever if notifyAll was skipped

        assert(atomicLoad(observed) == cast(int) OperationStatus.aborted,
               "a thread blocked in wait() must not be stranded by an Error");
    });
}

unittest // an out-of-range priority is rejected in every build, not only in debug
{
    import std.exception : assertThrown;

    withDispatcher((d, loop) {
        // The bands are array indices, so these must not reach the queue.
        assertThrown(d.invokeAsync({ }, DispatcherPriority.invalid));
        assertThrown(d.invokeAsync({ }, cast(DispatcherPriority) 99));

        // invoke() additionally refuses a band the pump never dispatches:
        // from another thread it would block its caller forever.
        assertThrown(d.invoke({ }, DispatcherPriority.inactive));

        // The operation's own setter is guarded the same way.
        auto op = d.invokeAsync({ });
        bool threw;
        try
            op.priority = DispatcherPriority.invalid;
        catch (Exception)
            threw = true;

        assert(threw, "changing an operation's priority is validated too");
        assert(op.priority == DispatcherPriority.normal, "...and leaves it untouched");
    });
}
