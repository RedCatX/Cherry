module cherry.core.dispatcher.timer;

import core.time : Duration, MonoTime;

import cherry.core.multicast;
import cherry.core.dispatcher.dispatcher;
import cherry.core.dispatcher.types;
import cherry.core.value;

/**
 * A delegate type for handling timer ticks.
 */
alias DispatcherTimerHandler = void delegate(DispatcherTimer timer);

/**
 * A timer whose ticks arrive on the dispatcher thread, at a priority of the
 * caller's choosing.
 *
 * A tick is posted to the queue rather than delivered from the timer itself,
 * so it takes its turn among everything else the dispatcher has to do: a
 * background timer will not interrupt input handling, and a busy dispatcher
 * delays the tick instead of running it concurrently.  Ticks are therefore
 * not precise -- an interval is the earliest a tick may arrive, not a
 * promise of when it will.
 *
 * A period is measured from the moment the previous one was found to be due,
 * so a slow handler does not accumulate a backlog of ticks: at most one tick
 * per timer is outstanding at a time.
 *
 * Timers belong to the thread that created them: start, stop and the
 * property setters verify that.
 */
final class DispatcherTimer : DispatcherObject
{
    this(DispatcherPriority priority = DispatcherPriority.background)
    {
        _priority = priority;
    }

    /// ditto
    this(Duration interval, DispatcherPriority priority = DispatcherPriority.background)
    {
        this(priority);
        _interval = interval;
    }

   /**
    * How long to wait between ticks.  Setting it while the timer runs
    * restarts the current period.  A zero interval means "every pass of the
    * dispatcher", which is as often as the priority allows.
    */
    @property Duration interval() const pure nothrow @nogc
    {
        return _interval;
    }

    /// ditto
    @property void interval(Duration value)
    {
        verifyAccess();

        if (value < Duration.zero)
            throw new Exception("A timer interval cannot be negative.");

        _interval = value;

        if (_enabled)
            _dueAt = MonoTime.currTime + value;
    }

   /**
    * The priority the tick is posted at.
    */
    @property DispatcherPriority priority() const pure nothrow @nogc
    {
        return _priority;
    }

   /**
    * Whether the timer is running.  Assigning is start() or stop().
    */
    @property bool enabled() const pure nothrow @nogc
    {
        return _enabled;
    }

    /// ditto
    @property void enabled(bool value)
    {
        if (value)
            start();
        else
            stop();
    }

   /**
    * Any data that the caller wants to pass along with the timer.
    */
    @property const(Value) tag() const pure nothrow @nogc
    {
        return _tag;
    }

    /// ditto
    @property void tag(Value value)
    {
        verifyAccess();
        _tag = value;
    }

   /**
    * Starts the timer, or does nothing if it is already running.  The first
    * tick is due one interval from now.
    */
    void start()
    {
        verifyAccess();

        if (_enabled)
            return;

        auto owner = cast(Dispatcher) dispatcher;

        _enabled = true;
        _dueAt = MonoTime.currTime + _interval;
        owner.addTimer(this);
    }

   /**
    * Stops the timer.  A tick already posted still runs: it is an ordinary
    * queued operation by then.
    */
    void stop()
    {
        verifyAccess();

        if (!_enabled)
            return;

        _enabled = false;

        if (auto owner = cast(Dispatcher) dispatcher)
            owner.removeTimer(this);
    }

   /**
    * Raised on the dispatcher thread each time the interval elapses.
    */
    @event @property auto onTick()
    {
        return eventAccessor(&_onTick);
    }

package:
   /*
    * When the next tick falls due.  Read by the dispatcher when it works out
    * how long it may sleep for.
    */
    @property MonoTime dueAt() const pure nothrow @nogc
    {
        return _dueAt;
    }

   /*
    * Opens the next period.  Called by the dispatcher as it posts the tick,
    * so the period runs from when the tick was found due rather than from
    * when the handler happened to run.
    */
    void openNextPeriod(MonoTime now)
    {
        _dueAt = now + _interval;
    }

   /*
    * The posted work itself.
    */
    void raiseTick()
    {
        _onTick(this);
    }

private:
    Duration           _interval;
    DispatcherPriority _priority;
    bool               _enabled;
    MonoTime           _dueAt;
    Value              _tag;

    Multicast!DispatcherTimerHandler _onTick;
}

/**
 * Unit tests for DispatcherTimer.
 */

version (unittest)
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import core.time : msecs;

    import cherry.core.dispatcher.testing;
}

unittest // ticks arrive on the dispatcher thread until the timer is stopped
{
    withDispatcher((d, loop) {
        auto owner = Thread.getThis();
        int ticks;
        bool alwaysOnOwner = true;

        auto timer = new DispatcherTimer(5.msecs, DispatcherPriority.normal);
        timer.onTick ~= (DispatcherTimer t) {
            ticks++;

            if (Thread.getThis() !is owner)
                alwaysOnOwner = false;

            if (ticks == 3)
            {
                t.stop();
                d.shutdown();
            }
        };

        assert(!timer.enabled);
        timer.start();
        assert(timer.enabled);

        pump(d);

        assert(ticks == 3, "the timer keeps ticking until it is stopped");
        assert(alwaysOnOwner, "a tick belongs to the dispatcher thread");
        assert(!timer.enabled);
    });
}

unittest // a stopped timer does not tick
{
    withDispatcher((d, loop) {
        int ticks;

        auto timer = new DispatcherTimer(5.msecs, DispatcherPriority.normal);
        timer.onTick ~= (DispatcherTimer t) { ticks++; };

        timer.start();
        timer.stop();

        // Long enough that a running timer would have ticked several times.
        auto stopper = new Thread({
            Thread.sleep(40.msecs);
            d.shutdown();
        }).start();

        pump(d);
        stopper.join();

        assert(ticks == 0);
    });
}

unittest // starting twice registers once, so a single stop is enough
{
    withDispatcher((d, loop) {
        int ticks;

        auto timer = new DispatcherTimer(5.msecs, DispatcherPriority.normal);
        timer.onTick ~= (DispatcherTimer t) { ticks++; };

        timer.start();
        timer.start();
        timer.stop();

        auto stopper = new Thread({
            Thread.sleep(40.msecs);
            d.shutdown();
        }).start();

        pump(d);
        stopper.join();

        assert(ticks == 0, "a second start must not register the timer twice");
    });
}

unittest // interval and priority
{
    withDispatcher((d, loop) {
        auto timer = new DispatcherTimer(20.msecs, DispatcherPriority.render);
        assert(timer.interval == 20.msecs);
        assert(timer.priority == DispatcherPriority.render);

        timer.interval = 5.msecs;
        assert(timer.interval == 5.msecs);

        bool refused;
        try
            timer.interval = -1.msecs;
        catch (Exception)
            refused = true;

        assert(refused, "a negative interval is rejected");

        // Ticks stay out of the way of input unless asked otherwise.
        auto quiet = new DispatcherTimer;
        assert(quiet.priority == DispatcherPriority.background);
    });
}
