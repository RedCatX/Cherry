module cherry.core.dispatcher;

import core.atomic : atomicLoad, atomicStore;
import core.sync.mutex : Mutex;
import core.thread : Thread;

import cherry.platform;

/**
 * Owns a thread's work queue and message loop -- the analogue of WPF's
 * Dispatcher.
 *
 * A dispatcher is bound to the thread that created it: checkAccess and
 * verifyAccess implement thread affinity, beginInvoke/invoke marshal work
 * onto the dispatcher thread from anywhere, and run pumps the underlying
 * platform EventLoop until shutdown.
 *
 * All queueing and scheduling live here, platform-independently; the only
 * platform-specific piece is the EventLoop supplied at construction.
 */
final class Dispatcher
{
   /**
    * The dispatcher of the calling thread, created on first use with the
    * platform's native event loop.
    */
    static @property Dispatcher current()
    {
        if (t_current is null)
            t_current = new Dispatcher(createPlatformEventLoop());
        return t_current;
    }

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

        _thread = Thread.getThis();
        _loop = loop;
        _queueMutex = new Mutex;
        t_current = this;
    }

   /**
    * The thread this dispatcher is bound to.
    */
    @property Thread thread() pure nothrow @nogc
    {
        return _thread;
    }

   /**
    * Whether the calling thread is the dispatcher's thread.
    */
    bool checkAccess() const
    {
        return Thread.getThis() is _thread;
    }

   /**
    * Throws when the calling thread is not the dispatcher's thread.
    */
    void verifyAccess() const
    {
        if (!checkAccess())
            throw new Exception(
                "The calling thread cannot access this object because a different thread owns it.");
    }

   /**
    * Thread-safe: queues work to run asynchronously on the dispatcher
    * thread.  Work queued from the dispatcher thread itself still runs
    * later, never inline.
    */
    void beginInvoke(void delegate() work)
    in {
        assert(work !is null);
    }
    do {
        if (atomicLoad(_shutdownRequested))
            throw new Exception("The dispatcher has been shut down.");

        synchronized (_queueMutex)
            _queue ~= work;

        // Scaffolding: once beginInvoke is itself marked shared, _loop is
        // seen as shared inside it and this cast can go away.
        (cast(shared) _loop).requestWake();
    }

   /**
    * Runs work on the dispatcher thread synchronously: inline when called
    * on the dispatcher thread, otherwise queued and awaited.  An exception
    * thrown by the work is rethrown on the calling thread.
    */
    void invoke(void delegate() work)
    in {
        assert(work !is null);
    }
    do {
        if (checkAccess())
        {
            work();
            return;
        }

        import core.sync.event : Event;

        Event completed;
        completed.initialize(true, false);
        scope (exit) completed.terminate();

        Throwable thrown;

        beginInvoke({
            try
                work();
            catch (Throwable t)
                thrown = t;

            completed.setIfInitialized();
        });

        completed.wait();

        if (thrown !is null)
            throw thrown;
    }

   /**
    * Pumps the event loop on the dispatcher thread until shutdown is
    * called.  Queued work is drained in FIFO order on every wake-up.
    */
    void run()
    {
        verifyAccess();

        _loop.run(&drainQueue);

        if (t_current is this)
            t_current = null;
    }

   /**
    * Thread-safe: stops the event loop.  Work still queued when the loop
    * exits is dropped, and later beginInvoke calls throw.
    */
    void shutdown()
    {
        atomicStore(_shutdownRequested, true);
        // Scaffolding: drop the cast once shutdown is marked shared.
        (cast(shared) _loop).quit();

        if (Thread.getThis() is _thread && t_current is this)
            t_current = null;
    }

private:
    void drainQueue()
    {
        while (true)
        {
            void delegate()[] batch;

            synchronized (_queueMutex)
            {
                if (_queue.length == 0)
                    return;

                batch = _queue;
                _queue = null;
            }

            foreach (work; batch)
                work();
        }
    }

    static Dispatcher t_current;   // thread-local: one dispatcher per thread

    Thread            _thread;
    EventLoop         _loop;
    Mutex             _queueMutex;
    void delegate()[] _queue;
    shared bool       _shutdownRequested;
}

unittest
{
    import std.exception : assertThrown;

    // Thread affinity and inline invoke on the owning thread.
    auto dispatcher = new Dispatcher(new ManualEventLoop);
    scope (exit) dispatcher.shutdown();

    assert(Dispatcher.current is dispatcher);
    assert(dispatcher.thread is Thread.getThis());
    assert(dispatcher.checkAccess());
    dispatcher.verifyAccess();

    // One dispatcher per thread.
    assertThrown(new Dispatcher(new ManualEventLoop));

    // invoke on the owning thread runs inline, without a pump.
    int calls;
    dispatcher.invoke({ calls++; });
    assert(calls == 1);
}

unittest
{
    import std.exception : assertThrown;

    // FIFO processing, shutdown from inside a work item, rejection after
    // shutdown.
    auto dispatcher = new Dispatcher(new ManualEventLoop);

    int[] order;
    dispatcher.beginInvoke({ order ~= 1; });
    dispatcher.beginInvoke({ order ~= 2; });
    dispatcher.beginInvoke({ order ~= 3; dispatcher.shutdown(); });

    dispatcher.run();

    assert(order == [1, 2, 3]);
    assertThrown(dispatcher.beginInvoke({ }));
}

unittest
{
    // Cross-thread marshaling over the portable loop.
    auto dispatcher = new Dispatcher(new ManualEventLoop);
    auto owner = Thread.getThis();

    bool beginInvokeOnOwner;
    bool invokeRan;
    bool accessDenied;
    bool exceptionMarshaled;

    auto worker = new Thread({
        scope (exit) dispatcher.shutdown();

        dispatcher.beginInvoke({
            beginInvokeOnOwner = (Thread.getThis() is owner);
        });

        dispatcher.invoke({ invokeRan = true; });

        if (!dispatcher.checkAccess())
        {
            try
                dispatcher.verifyAccess();
            catch (Exception)
                accessDenied = true;
        }

        try
            dispatcher.invoke({ throw new Exception("boom"); });
        catch (Exception e)
            exceptionMarshaled = (e.msg == "boom");
    });

    worker.start();
    dispatcher.run();
    worker.join();

    assert(beginInvokeOnOwner);
    assert(invokeRan);
    assert(accessDenied);
    assert(exceptionMarshaled);
}

unittest
{
    // End-to-end over the real platform loop (Win32 on Windows, the
    // portable fallback elsewhere) -- note: no version() blocks needed.
    auto dispatcher = new Dispatcher(createPlatformEventLoop());

    int processed;

    auto worker = new Thread({
        scope (exit) dispatcher.shutdown();

        foreach (i; 0 .. 5)
            dispatcher.beginInvoke({ processed++; });

        dispatcher.invoke({ });   // FIFO barrier: all five ran before this
    });

    worker.start();
    dispatcher.run();
    worker.join();

    assert(processed == 5);
}
