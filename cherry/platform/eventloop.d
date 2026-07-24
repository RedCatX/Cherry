module cherry.platform.eventloop;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;

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
                while (!_wakeRequested && !_quitRequested)
                    _condition.wait();

                // A pending wake is delivered before a pending quit.
                if (_wakeRequested)
                {
                    _wakeRequested = false;
                }
                else
                {
                    _quitRequested = false;
                    return;
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

private:
    Mutex     _mutex;
    Condition _condition;
    bool      _wakeRequested;
    bool      _quitRequested;
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
