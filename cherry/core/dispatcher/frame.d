module cherry.core.dispatcher.frame;

import core.atomic : atomicLoad, atomicStore;

import cherry.core.dispatcher.dispatcher;

/**
 * A nested run of the dispatcher's message loop, with an exit condition of
 * its own.
 *
 * Pushing a frame keeps the loop pumping -- timers keep ticking, posted work
 * keeps running -- while the code that pushed it waits.  That is what a modal
 * dialog needs: showDialog() blocks its caller without freezing the
 * application, and closing the dialog lets the frame return.
 * ---
 * auto frame = new DispatcherFrame;
 * window.onClosed ~= (Window w) { frame.resume = false; };
 * window.show();
 * Dispatcher.current.pushFrame(frame);   // returns once the window closes
 * ---
 * A frame also ends when the dispatcher shuts down and, unless it opted out,
 * when exitAllFrames() is called.
 */
final class DispatcherFrame
{
   /**
    * Params:
    *   exitsOnRequest = whether exitAllFrames() ends this frame.  A frame
    *                    with business of its own to finish first -- one
    *                    draining work as the application closes, say --
    *                    passes false and decides for itself.
    */
    this(bool exitsOnRequest = true)
    {
        _exitsOnRequest = exitsOnRequest;
        atomicStore(_resume, true);
    }

   /**
    * Whether the loop should keep pumping.  It is read after every pass, so
    * clearing it from a handler ends the frame as soon as that pass finishes.
    *
    * Settable from any thread: the setter wakes the loop, so a frame stopped
    * from a worker does not sit idle until the next event happens to arrive.
    */
    @property bool resume() const
    {
        return atomicLoad(_resume);
    }

    /// ditto
    @property void resume(bool value)
    {
        atomicStore(_resume, value);

        // The loop may be blocked on something that will never come.
        if (auto owner = atomicLoad(_dispatcher))
            owner.wake();
    }

   /**
    * Whether exitAllFrames() ends this frame.
    */
    @property bool exitsOnRequest() const pure nothrow @nogc
    {
        return _exitsOnRequest;
    }

package:
   /*
    * The dispatcher is recorded when the frame is pushed rather than taken at
    * construction: a frame is often built before the dispatcher it will run
    * on is reachable, and this way there is nothing to race with.
    */
    void enter(shared(Dispatcher) owner)
    {
        atomicStore(_dispatcher, owner);
    }

    /// ditto
    void leave()
    {
        atomicStore(_dispatcher, cast(shared(Dispatcher)) null);
    }

private:
    shared bool        _resume;
    shared(Dispatcher) _dispatcher;
    immutable bool     _exitsOnRequest;
}

/**
 * Unit tests for DispatcherFrame.
 */

version (unittest)
{
    import core.thread : Thread;
    import core.time : msecs;

    import cherry.core.dispatcher.testing;
    import cherry.core.dispatcher.types;
}

unittest // a frame pumps its own work, returns, and the outer loop carries on
{
    withDispatcher((d, loop) {
        int[] order;
        bool outerResumed;

        d.invokeAsync({
            order ~= 1;

            auto frame = new DispatcherFrame;

            // Work queued from inside the frame still runs: a frame is a
            // second pump, not a pause.
            d.invokeAsync({
                order ~= 2;
                frame.resume = false;
            });

            (cast(Dispatcher) d).pushFrame(frame);
            order ~= 3;                  // reached only once the frame returns
        });

        // Lower priority, so it is left over for the outer loop to pick up
        // after the frame has finished.
        d.invokeAsync({ outerResumed = true; d.shutdown(); },
                      DispatcherPriority.background);

        pump(d);

        assert(order == [1, 2, 3], "the frame runs its work and then returns");
        assert(outerResumed, "the outer loop keeps pumping once the frame is gone");
    });
}

unittest // shutdown from inside a nested frame unwinds every level
{
    withDispatcher((d, loop) {
        bool frameReturned;
        bool endedByShutdown;

        d.invokeAsync({
            auto frame = new DispatcherFrame;

            d.invokeAsync({ d.shutdown(); });     // never touches resume

            (cast(Dispatcher) d).pushFrame(frame);

            frameReturned = true;
            endedByShutdown = frame.resume;
        });

        pump(d);   // hangs if the inner loop swallowed the quit

        assert(frameReturned, "the nested frame returns when the dispatcher shuts down");
        assert(endedByShutdown, "...and the shutdown, not its own flag, is what ended it");
    });
}

unittest // exitAllFrames ends the frames that opted in
{
    withDispatcher((d, loop) {
        bool returned;

        d.invokeAsync({
            auto frame = new DispatcherFrame;      // exitsOnRequest defaults to true

            d.invokeAsync({ d.exitAllFrames(); });

            (cast(Dispatcher) d).pushFrame(frame);
            returned = true;
            d.shutdown();
        });

        pump(d);

        assert(returned);
    });
}

unittest // a frame that opted out ignores exitAllFrames
{
    withDispatcher((d, loop) {
        bool stoppedExplicitly;

        d.invokeAsync({
            auto frame = new DispatcherFrame(false);

            d.invokeAsync({
                d.exitAllFrames();

                // The frame is still up, so ending it takes an explicit ask.
                d.invokeAsync({
                    stoppedExplicitly = true;
                    frame.resume = false;
                });
            });

            (cast(Dispatcher) d).pushFrame(frame);
            d.shutdown();
        });

        pump(d);

        assert(stoppedExplicitly, "exitAllFrames must leave an opted-out frame alone");
    });
}

unittest // a frame cannot be pushed once the dispatcher is down
{
    import std.exception : assertThrown;

    withDispatcher((d, loop) {
        d.shutdown();
        assertThrown((cast(Dispatcher) d).pushFrame(new DispatcherFrame));
    });
}

unittest // a frame can be stopped from another thread
{
    withDispatcher((d, loop) {
        bool returned;

        d.invokeAsync({
            auto frame = new DispatcherFrame;

            // Nothing else is queued, so the loop blocks: only the wake the
            // setter issues can bring it back.
            auto stopper = new Thread({
                Thread.sleep(20.msecs);
                frame.resume = false;
            }).start();

            (cast(Dispatcher) d).pushFrame(frame);

            returned = true;
            stopper.join();
            d.shutdown();
        });

        pump(d);

        assert(returned, "clearing resume from a worker wakes the blocked loop");
    });
}
