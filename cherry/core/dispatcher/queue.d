module cherry.core.dispatcher.queue;

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;

import cherry.core.dispatcher.operation;
import cherry.core.dispatcher.types;

/**
 * Class PriorityQueue represents a thread-safe Dispatcher queue. 
 * Only this class may safe change protected fields _qNode and _priority
 * of class DispatcherOperation and protect his by own mutex.
 */
package final class PriorityQueue
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
    import core.atomic : atomicOp;
    import core.thread : Thread;

    import cherry.core.dispatcher.testing;
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
