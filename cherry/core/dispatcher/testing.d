module cherry.core.dispatcher.testing;

/**
 * Helpers shared by the unit tests of the modules in this package.  The whole
 * module is behind version(unittest), so importing it from production code
 * costs nothing.
 */

version (unittest):

import core.thread : Thread;

import cherry.platform;
import cherry.core.dispatcher.dispatcher;
import cherry.core.dispatcher.operation;
import cherry.core.dispatcher.queue;
import cherry.core.dispatcher.types;

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
	*/
    package void withDispatcher(EventLoop loop, scope void delegate(shared(Dispatcher)) body)
    {
        auto d = cast(shared) new Dispatcher(loop);
        scope (exit) d.shutdown();
        body(d);
    }

    /// Convenience overload for the common ManualEventLoop case.
    package void withDispatcher(scope void delegate(shared(Dispatcher), ManualEventLoop) body)
    {
        auto loop = new ManualEventLoop;
        withDispatcher(loop, (shared(Dispatcher) d) { body(d, loop); });
    }

    /// Pumps the loop on this thread until something calls shutdown.
    package void pump(shared(Dispatcher) d)
    {
        (cast(Dispatcher) d).run();
    }

    /**
	* Drains everything currently queued, then stops.  The sentinel sits at
	* the lowest dispatchable band, so it runs only once all real work is
	* done.  Valid only while isInputPending is false.
	*/
    package void pumpUntilIdle(shared(Dispatcher) d)
    {
        d.invokeAsync({ d.shutdown(); }, DispatcherPriority.systemIdle);
        pump(d);
    }
