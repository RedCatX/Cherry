module cherry.core.dispatcher.dispatcher;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : Duration, MonoTime, dur;

import cherry.core.multicast;
import cherry.platform;
import cherry.core.dispatcher.frame;
import cherry.core.dispatcher.operation;
import cherry.core.dispatcher.queue;
import cherry.core.dispatcher.timer;
import cherry.core.dispatcher.types;

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

    @property shared(Dispatcher) dispatcher() pure nothrow @nogc
    {
        return _dispatcher;
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
 * A delegate type for reporting an exception that escaped a dispatcher
 * operation and that nothing else is going to observe.
 *
 * Setting handled says the failure has been dealt with.  The dispatcher
 * itself carries on either way -- one broken handler must not take the pump
 * down with it -- so the flag is there for the handlers to coordinate: an
 * application can report what nobody else claimed, and stay quiet about
 * what somebody did.
 */
alias DispatcherUnhandledExceptionHandler =
    void delegate(shared(DispatcherOperation) op, Exception exception, ref bool handled);

/**
 * A delegate type for handling the two ends of a dispatcher shutdown.
 */
alias DispatcherShutdownHandler = void delegate(shared(Dispatcher) dispatcher);

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
    * Whether shutdown has been asked for.  Set as soon as shutdown() is
    * called, from whichever thread called it.
    */
    @property bool hasShutdownStarted() shared const
    {
        return atomicLoad(_shutdownStarted);
    }

   /**
    * Whether the shutdown has run its course: the pump has unwound, the
    * queue is closed and its operations released.  A dispatcher shut down
    * without ever having been pumped never reaches this -- there is no
    * dispatcher thread to finish on -- though its queue is still released.
    */
    @property bool hasShutdownFinished() shared const
    {
        return atomicLoad(_shutdownFinished);
    }

   /**
    * Raised on the dispatcher thread once the pump has unwound, before the
    * queue is closed.  A handler runs inline and should wind up its
    * business there and then: work posted from it is aborted along with
    * whatever else was still queued.
    */
    @event @property auto onShutdownStarted() shared
    {
        auto self = cast(Dispatcher) this;

        return EventAccessor!DispatcherShutdownHandler(
            (DispatcherShutdownHandler h)
            {
                synchronized (self._eventMutex)
                    self._onShutdownStarted.add(h);
            },
            (DispatcherShutdownHandler h)
            {
                synchronized (self._eventMutex)
                    self._onShutdownStarted.remove(h);
            });
    }

   /**
    * Raised on the dispatcher thread after the queue has been closed and
    * everything left in it released.  Posting is no longer possible by
    * then; this is for releasing what the thread still holds.
    */
    @event @property auto onShutdownFinished() shared
    {
        auto self = cast(Dispatcher) this;

        return EventAccessor!DispatcherShutdownHandler(
            (DispatcherShutdownHandler h)
            {
                synchronized (self._eventMutex)
                    self._onShutdownFinished.add(h);
            },
            (DispatcherShutdownHandler h)
            {
                synchronized (self._eventMutex)
                    self._onShutdownFinished.remove(h);
            });
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
    * Runs a nested loop until the frame is told to stop.
    *
    * Everything the dispatcher would normally do carries on while the frame
    * runs -- this is a second pump, not a pause -- so the caller blocks
    * without the application going dead.  The frame ends when its resume
    * property is cleared, when the dispatcher shuts down, or, unless it
    * opted out, when exitAllFrames() is called.
    */
    void pushFrame(DispatcherFrame frame)
    in {
        assert(frame !is null);
    }
    do {
        verifyAccess();

        if (atomicLoad(_shutdownStarted))
            throw new Exception("The dispatcher has been shut down.");

        frame.enter(cast(shared) this);
        atomicOp!"+="(_frameDepth, 1);

        scope (exit)
        {
            atomicOp!"-="(_frameDepth, 1);
            frame.leave();

            if (atomicLoad(_frameDepth) == 0)
            {
                // The request is spent once the outermost frame has unwound.
                atomicStore(_exitAllFramesRequested, false);

                // The outermost pump owns the rest of the shutdown, whether
                // it was entered through run() or pushFrame() directly.
                if (atomicLoad(_shutdownStarted))
                    finishShutdown();
            }
        }

        // The queue is drained before the condition is read: the handler
        // that ends the frame runs inside processQueue.
        _loop.run({
            processQueue();
            return keepPumping(frame);
        });
    }

   /**
    * Asks every frame that opted in to return, innermost first.  The
    * dispatcher itself keeps running: this ends the nested loops, not the
    * pump.
    */
    void exitAllFrames() shared
    {
        atomicStore(_exitAllFramesRequested, true);
        _loop.requestWake();
    }

   /**
    * Pumps the event loop on the dispatcher thread until shutdown is
    * called.  Queued work is drained in FIFO order on every wake-up.
    */
    void run()
    {
        verifyAccess();

        // Nothing to pump if the dispatcher is already down, but the
        // shutdown still has to be seen through.
        if (!atomicLoad(_shutdownStarted))
            pushFrame(new DispatcherFrame);

        finishShutdown();
    }

   /**
    * Thread-safe: stops the event loop.  Work still queued when the loop
    * exits is dropped, and later invokeAsync calls throw.
    */
    void shutdown() shared
    {
        atomicStore(_shutdownStarted, true);
        _loop.quit();

        // A running pump owns the rest, and does it on its own thread so
        // that the handlers of the shutdown events run where they expect to.
        if (atomicLoad(_frameDepth) > 0)
            return;

        // Nothing is pumping and perhaps nothing ever will, so the queue has
        // to be released here: leaving it would strand its operations, and
        // any thread blocked in wait() along with them.  The events are not
        // raised -- there is no dispatcher thread running to raise them on.
        foreach (op; _queue.close())
            op.setAborted();

        if (Thread.getThis().id == _threadId && (cast(shared) t_current) is this)
            t_current = null;
    }

package:
   /*
    * Nudges the loop so it re-reads whatever condition just changed.
    */
    void wake() shared
    {
        _loop.requestWake();
    }

   /*
    * Timer registration.  Both run on the dispatcher thread -- start() and
    * stop() verify that -- so the list needs no lock of its own.
    */
    void addTimer(DispatcherTimer timer)
    {
        foreach (registered; _timers)
            if (registered is timer)
                return;

        _timers ~= timer;
    }

    /// ditto
    void removeTimer(DispatcherTimer timer)
    {
        foreach (i, registered; _timers)
        {
            if (registered is timer)
            {
                _timers = _timers[0 .. i] ~ _timers[i + 1 .. $];
                return;
            }
        }
    }

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

        // Passed to every handler in turn, so a later one can see that an
        // earlier one already dealt with the failure.
        bool handled;

        try
            handlers(op, exception, handled);
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

   /*
    * The closing half of a shutdown, always on the dispatcher thread.  Runs
    * once: whichever of run() or the outermost pushFrame() gets here first
    * does the work.
    */
    void finishShutdown()
    {
        if (!atomicLoad(_shutdownStarted) || atomicLoad(_shutdownFinished))
            return;

        // Raised while the queue is still open, so a handler can still post
        // the work it needs to wind up.
        raiseShutdown(_onShutdownStarted);

        // Nobody will ever run what is left; releasing it wakes any thread
        // blocked in wait() instead of leaving it stuck forever.
        foreach (op; _queue.close())
            op.setAborted();

        // Nothing will tick once the pump is gone.
        _timers = null;

        atomicStore(_shutdownFinished, true);
        raiseShutdown(_onShutdownFinished);

        if (t_current is this)
            t_current = null;
    }

   /*
    * Snapshot under the lock, deliver outside it.  A handler that throws is
    * swallowed: one of them failing must not leave the shutdown half done.
    */
    void raiseShutdown(ref Multicast!DispatcherShutdownHandler event)
    {
        Multicast!DispatcherShutdownHandler handlers;

        synchronized (_eventMutex)
            handlers = event.dup;

        try
            handlers(cast(shared) this);
        catch (Exception)
        {
        }
    }

   /*
    * Whether the frame currently being pumped should stay in its loop.
    */
    bool keepPumping(DispatcherFrame frame)
	{
		if (!frame.resume)
			return false;

		if (atomicLoad(_shutdownStarted))
			return false;

		return !(frame.exitsOnRequest && atomicLoad(_exitAllFramesRequested));
	}

    bool isForeground(DispatcherPriority p)
	{
        return (p >= DispatcherPriority.input && p <= DispatcherPriority.send);
	}

    void processQueue()
	{
		while (!atomicLoad(_shutdownStarted))
		{
			postDueTicks();

			DispatcherPriority p;
			if ((p = _queue.highestPriority) <= DispatcherPriority.inactive) 
			{ 
				_backgroundDeadline = MonoTime.zero; 
				break; 
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

				break;
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

		if (!atomicLoad(_shutdownStarted))
			scheduleNextWake();
	}

   /*
    * Posts a tick for every timer that has come due and opens its next
    * period.  The list is copied first: a tick handler is free to start or
    * stop timers.
    */
    void postDueTicks()
	{
		if (_timers.length == 0)
			return;

		immutable now = MonoTime.currTime;

		foreach (timer; _timers.dup)
		{
			if (timer.dueAt > now)
				continue;

			timer.openNextPeriod(now);
			(cast(shared) this).post(&timer.raiseTick, timer.priority, false);
		}
	}

   /*
    * The loop offers a single deferred wake, so everything that wants one
    * -- the starvation guard and every running timer -- is multiplexed onto
    * the earliest deadline among them.
    */
    void scheduleNextWake()
	{
		MonoTime earliest;   // MonoTime.zero means nothing is waiting

		if (_backgroundDeadline != MonoTime.zero)
			earliest = _backgroundDeadline;

		foreach (timer; _timers)
			if (earliest == MonoTime.zero || timer.dueAt < earliest)
				earliest = timer.dueAt;

		if (earliest == MonoTime.zero)
			return;

		immutable now = MonoTime.currTime;
		_loop.requestWakeAfter(earliest > now ? earliest - now : Duration.zero);
	}

    enum Duration BACKGROUND_PROMOTION_DELAY = dur!"msecs"(50);

    static Dispatcher t_current;   // thread-local: one dispatcher per thread

    immutable uint    _threadId;
    EventLoop         _loop;
    MonoTime          _backgroundDeadline;
    DispatcherTimer[] _timers;
    shared bool       _shutdownStarted;
    shared bool       _shutdownFinished;
    shared int        _frameDepth;
    shared bool       _exitAllFramesRequested;
    Mutex             _eventMutex;
    Multicast!DispatcherUnhandledExceptionHandler _onUnhandledException;
    Multicast!DispatcherShutdownHandler           _onShutdownStarted;
    Multicast!DispatcherShutdownHandler           _onShutdownFinished;

package:
    shared(PriorityQueue) _queue;
}

/**
 * Unit tests for Dispatcher: scheduling policy, queueing semantics and the
 * lifecycle of the pump itself.
 */

version (unittest)
{
    import core.atomic : atomicOp;
    import core.time : msecs;

    import cherry.core.dispatcher.testing;
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

        d.onUnhandledException ~= (shared(DispatcherOperation) op, Exception e, ref bool handled) {
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

        d.onUnhandledException ~= (shared(DispatcherOperation) op, Exception e, ref bool handled) {
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

        d.onUnhandledException ~= (shared(DispatcherOperation) op, Exception e, ref bool handled) {
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

        void onFailure(shared(DispatcherOperation) op, Exception e, ref bool handled)
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

// ===========================================================================
// Dispatcher: shutdown lifecycle
// ===========================================================================

unittest // the events bracket the closing of the queue, on the owning thread
{
    withDispatcher((d, loop) {
        auto owner = Thread.getThis();

        string[] order;
        bool startedOnOwner, finishedOnOwner;
        bool finishedFlagAtStart, finishedFlagAtEnd;

        assert(!d.hasShutdownStarted);
        assert(!d.hasShutdownFinished);

        d.onShutdownStarted ~= (shared(Dispatcher) sender) {
            order ~= "started";
            startedOnOwner = Thread.getThis() is owner;
            finishedFlagAtStart = sender.hasShutdownFinished;
        };

        d.onShutdownFinished ~= (shared(Dispatcher) sender) {
            order ~= "finished";
            finishedOnOwner = Thread.getThis() is owner;
            finishedFlagAtEnd = sender.hasShutdownFinished;
        };

        d.invokeAsync({ d.shutdown(); });
        pump(d);

        assert(order == ["started", "finished"]);
        assert(startedOnOwner && finishedOnOwner, "handlers belong to the dispatcher thread");
        assert(!finishedFlagAtStart, "the first event comes before the queue is closed");
        assert(finishedFlagAtEnd, "...and the second after");
        assert(d.hasShutdownStarted && d.hasShutdownFinished);
    });
}

unittest // a shutdown asked for from another thread still finishes on the owner
{
    withDispatcher((d, loop) {
        auto owner = Thread.getThis();

        shared bool startedOnOwner;
        shared bool finishedOnOwner;

        d.onShutdownStarted ~= (shared(Dispatcher) sender) {
            atomicStore(startedOnOwner, Thread.getThis() is owner);
        };

        d.onShutdownFinished ~= (shared(Dispatcher) sender) {
            atomicStore(finishedOnOwner, Thread.getThis() is owner);
        };

        auto worker = new Thread({
            Thread.sleep(20.msecs);
            d.shutdown();
        }).start();

        pump(d);
        worker.join();

        assert(atomicLoad(startedOnOwner),
               "the handlers must not run on the thread that asked for the shutdown");
        assert(atomicLoad(finishedOnOwner));
    });
}

unittest // shutting down a dispatcher that never pumped still releases its work
{
    auto loop = new ManualEventLoop;
    auto d = cast(shared) new Dispatcher(loop);

    bool everRaised;
    d.onShutdownFinished ~= (shared(Dispatcher) sender) { everRaised = true; };

    auto op = d.invokeAsync({ });
    d.shutdown();

    assert(d.hasShutdownStarted);
    assert(op.status == OperationStatus.aborted,
           "queued work is released even with nothing pumping");
    assert(!d.hasShutdownFinished,
           "there is no dispatcher thread to finish the shutdown on");
    assert(!everRaised, "...so the events stay silent rather than run on a foreign thread");
}

unittest // a handler that throws must not leave the shutdown half done
{
    withDispatcher((d, loop) {
        bool finished;

        d.onShutdownStarted ~= (shared(Dispatcher) sender) {
            throw new Exception("the handler is broken");
        };

        d.onShutdownFinished ~= (shared(Dispatcher) sender) { finished = true; };

        d.invokeAsync({ d.shutdown(); });
        pump(d);

        assert(finished, "the shutdown runs to completion regardless");
        assert(d.hasShutdownFinished);
    });
}

unittest // handlers coordinate through the handled flag
{
    withDispatcher((d, loop) {
        bool sawHandledFromEarlier;

        d.onUnhandledException ~= (shared(DispatcherOperation) op, Exception e, ref bool handled) {
            handled = true;
        };

        d.onUnhandledException ~= (shared(DispatcherOperation) op, Exception e, ref bool handled) {
            sawHandledFromEarlier = handled;
        };

        bool laterRan;
        d.invokeAsync({ throw new Exception("boom"); });
        d.invokeAsync({ laterRan = true; });
        pumpUntilIdle(d);

        assert(sawHandledFromEarlier,
               "a handler sees that an earlier one claimed the failure");
        assert(laterRan, "the pump carries on whether or not anyone claimed it");
    });
}
