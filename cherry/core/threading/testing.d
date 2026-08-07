module cherry.core.threading.testing;

/**
 * Helpers shared by the unit tests of the modules in this package.  The whole
 * module is behind version(unittest), so importing it from production code
 * costs nothing.
 */

version (unittest):

import core.thread : Thread;

import cherry.platform;
import cherry.core.threading.dispatcher;
import cherry.core.threading.operation;
import cherry.core.threading.queue;
import cherry.core.threading.types;

    import core.thread : Thread;
    import core.atomic : atomicOp;

    /**
	* Builds a detached operation.  The dispatcher reference stays null on
	* purpose: none of these tests call abort() or invoke(), so the queue is
	* exercised in isolation.
	*/
    package shared(DispatcherOperation) makeOp(DispatcherPriority p)
    {
        return cast(shared) new DispatcherOperation(null, delegate void() {}, p);
    }

    /// Unwraps to the mutable view so tests can read queue-owned fields.
    package DispatcherOperation raw(shared(DispatcherOperation) op)
    {
        return cast(DispatcherOperation) op;
    }

    /// Pops everything the queue is willing to hand out, in order.
    package shared(DispatcherOperation)[] drain(shared(PriorityQueue) q)
    {
        shared(DispatcherOperation)[] result;
        for (auto op = q.dequeue(); op !is null; op = q.dequeue())
            result ~= op;
        return result;
    }

    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import core.time : MonoTime, msecs;

    /**
	* Runs body with a dispatcher driven by the supplied loop, releasing the
	* thread-local slot afterwards whatever happens.
	*
	* package(cherry) rather than package: anything built on the dispatcher
	* needs a dispatcher it can step by hand to test against, and cherry.ui
	* would otherwise have to keep a second copy of these.
	*/
    package(cherry) void withDispatcher(EventLoop loop, scope void delegate(shared(Dispatcher)) body)
    {
        releaseAmbientDispatcher();

        auto d = cast(shared) new Dispatcher(loop);
        scope (exit) d.shutdown();
        body(d);
    }

    /**
	* Clears whatever dispatcher this thread is already carrying.
	*
	* A DispatcherObject binds to Dispatcher.current, which creates one on
	* demand, so any test that builds an object outside a helper leaves the
	* thread holding a dispatcher on the platform's own event loop.  A thread
	* hosts one dispatcher at a time, so the next test to ask for its own
	* would be refused -- and it wants its own, on a loop it can step by hand.
	*/
    package(cherry) void releaseAmbientDispatcher()
    {
        if (auto ambient = Dispatcher.currentOrNull)
            ambient.shutdown();
    }

    /// Convenience overload for the common ManualEventLoop case.
    package(cherry) void withDispatcher(scope void delegate(shared(Dispatcher), ManualEventLoop) body)
    {
        auto loop = new ManualEventLoop;
        withDispatcher(loop, (shared(Dispatcher) d) { body(d, loop); });
    }

    /// Pumps the loop on this thread until something calls shutdown.
    package(cherry) void pump(shared(Dispatcher) d)
    {
        (cast(Dispatcher) d).run();
    }

    /**
	* Drains everything currently queued, then stops.  The sentinel sits at
	* the lowest dispatchable band, so it runs only once all real work is
	* done.  Valid only while isInputPending is false.
	*/
    package(cherry) void pumpUntilIdle(shared(Dispatcher) d)
    {
        d.invokeAsync({ d.shutdown(); }, DispatcherPriority.systemIdle);
        pump(d);
    }
