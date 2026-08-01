module cherry.platform.eventloop;

import core.atomic : atomicLoad, atomicStore;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.time : Duration, MonoTime;

/**
 * The platform seam of the dispatcher: everything the framework needs from
 * a native message loop, reduced to three operations (the analogue of
 * Avalonia's IPlatformThreadingInterface).
 *
 * The dispatcher owns the work queue and all scheduling policy; an
 * EventLoop only pumps platform events and wakes the dispatcher on request.
 */
interface EventLoop
{
   /**
    * Runs the loop on the current thread until quit is called.
    *
    * onWake is invoked on this thread once on entry (draining work queued
    * before the loop started) and then after every wake request.
    *
    * Deliberately not shared: only the owning thread may pump the loop, and
    * the unshared reference is what expresses that.
    */
    void run(scope void delegate() onWake);

   /**
    * Makes run return.  A wake request already pending at that moment is
    * still delivered first.
    *
    * Shared: callable from any thread.  Other threads hold a shared view of
    * the loop, through which quit and requestWake are the only operations
    * available.
    */
    void quit() shared;

   /**
    * Schedules an onWake invocation on the loop thread.  Consecutive
    * requests may coalesce into a single invocation.
    *
    * Shared: callable from any thread.
    */
    void requestWake() shared;

   /**
    * Whether native input is waiting to be processed.
    *
    * Meaningful only on the loop thread -- it inspects that thread's input
    * queue -- so it is not shared.  The dispatcher uses it to hold back
    * background work while the user is actively interacting.
    */
    bool isInputPending();

   /**
    * Schedules a wake no sooner than `delay` from now, replacing any pending
    * deferred wake (at most one outstanding).  It is ordered behind native
    * input, so it serves both as the starvation guard for deferred
    * background work and as the "input has drained" re-wake.
    *
    * Owner-thread only, like run: it drives a timer bound to the loop thread.
    */
    void requestWakeAfter(Duration delay);
}

/**
 * Portable EventLoop built on a condition variable: no native events, just
 * wake requests.  Serves as the dispatcher test double and as the headless
 * fallback on platforms without a native implementation yet.
 */
final class ManualEventLoop : EventLoop
{
    this()
    {
        _mutex = new Mutex;
        _condition = new Condition(_mutex);
    }

    void run(scope void delegate() onWake)
    {
        onWake();

        while (true)
        {
            synchronized (_mutex)
            {
                while (true)
                {
                    // A pending wake is delivered before a pending quit.
                    if (_wakeRequested)
                    {
                        _wakeRequested = false;
                        break;
                    }

                    // A deferred wake whose deadline has arrived is delivered
                    // as an ordinary wake.
                    if (_hasDeadline && MonoTime.currTime >= _deadline)
                    {
                        _hasDeadline = false;
                        break;
                    }

                    if (_quitRequested)
                    {
                        _quitRequested = false;
                        return;
                    }

                    if (_hasDeadline)
                        _condition.wait(_deadline - MonoTime.currTime);
                    else
                        _condition.wait();
                }
            }

            onWake();
        }
    }

    void quit() shared
    {
        // The mutex serializes every access to the flags; the cast states
        // what the lock already guarantees.
        auto self = cast(ManualEventLoop) this;

        synchronized (self._mutex)
        {
            self._quitRequested = true;
            self._condition.notifyAll();
        }
    }

    void requestWake() shared
    {
        auto self = cast(ManualEventLoop) this;

        synchronized (self._mutex)
        {
            self._wakeRequested = true;
            self._condition.notifyAll();
        }
    }

    bool isInputPending()
    {
        return atomicLoad(_inputPending);
    }

    void requestWakeAfter(Duration delay)
    {
        // Owner-thread only: this runs from within onWake, when the loop is
        // not waiting, so a plain field write is enough -- the cross-thread
        // requestWake/quit never touch the deadline.
        _deadline = MonoTime.currTime + delay;
        _hasDeadline = true;
    }

   /**
    * Test knob: the value isInputPending will report.  Atomic so a test can
    * flip it from another thread.
    */
    @property void inputPending(bool value)
    {
        atomicStore(_inputPending, value);
    }

private:
    Mutex       _mutex;
    Condition   _condition;
    bool        _wakeRequested;
    bool        _quitRequested;
    bool        _hasDeadline;
    MonoTime    _deadline;
    shared bool _inputPending;
}

unittest
{
    import core.thread : Thread;

    auto loop = new ManualEventLoop;
    int wakes;

    // Other threads see the loop through a shared reference, which limits
    // them to requestWake and quit; run stays with the owning thread.
    auto remote = cast(shared) loop;

    auto worker = new Thread({
        foreach (i; 0 .. 3)
            remote.requestWake();
        remote.quit();
    });

    worker.start();
    loop.run({ wakes++; });
    worker.join();

    // One initial drain plus one to three wake deliveries: consecutive
    // requests are allowed to coalesce into a single flag.
    assert(wakes >= 2 && wakes <= 4);
}

unittest
{
    import core.time : msecs, MonoTime;

    // isInputPending mirrors the test knob.
    auto loop = new ManualEventLoop;
    assert(!loop.isInputPending());
    loop.inputPending = true;
    assert(loop.isInputPending());
    loop.inputPending = false;

    // requestWakeAfter delivers a wake on its own, with no requestWake/quit,
    // after roughly the requested delay.
    int wakes;
    auto start = MonoTime.currTime;
    MonoTime secondWakeAt;

    loop.run({
        wakes++;
        if (wakes == 1)
            loop.requestWakeAfter(30.msecs);   // armed from the initial drain
        else
        {
            secondWakeAt = MonoTime.currTime;
            (cast(shared) loop).quit();
        }
    });

    assert(wakes == 2);
    assert(secondWakeAt - start >= 25.msecs);
}
