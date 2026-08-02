module cherry.core.dispatcher.operation;

import core.atomic : atomicLoad, atomicStore;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;

import cherry.core.multicast;
import cherry.core.dispatcher.dispatcher;
import cherry.core.dispatcher.queue;
import cherry.core.dispatcher.types;

/**
 * A delegate type for handling DispatcherOperation events.
 */
alias DispatcherOperationEventHandler = void delegate(shared(DispatcherOperation) op);

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

package:
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
 * Unit tests for DispatcherOperation.
 */

version (unittest)
{
    import core.thread : Thread;
    import core.time : msecs;

    import cherry.core.dispatcher.testing;
    import cherry.platform;
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
