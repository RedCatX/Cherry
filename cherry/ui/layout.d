module cherry.ui.layout;

/*
 * NO MODULE CONSTRUCTOR IN THIS FILE.  Not `shared static this()`, not
 * `static this()`.
 *
 * This module and cherry.ui.element import each other: an element asks for the
 * manager when it goes out of date, and the manager lays elements out.
 * element.d already has a module constructor -- it registers the Width, Height,
 * ActualWidth and ActualHeight properties -- and D orders module constructors
 * by the import graph, which a cycle leaves no order to choose.  A second
 * constructor in the cycle aborts the runtime before main() with
 *
 *     object.Error@src\rt\minfo.d(372): Cyclic dependency between module
 *     constructors/destructors of cherry.ui.element and cherry.ui.layout
 *
 * for every program built against the framework, tests included, and nothing
 * in that message points at what caused it.  cherry.ui.application carries the
 * same warning for the same reason.
 *
 * For the same reason this module must not import cherry.ui.window, which has
 * a module constructor of its own.  It does not need to: an element that is
 * the top of a subtree being laid out is asked to measure itself through
 * measureAsRoot, and Window overrides that to supply the size the platform
 * gave it.
 */

import cherry.core.threading;
import cherry.ui.element;

/**
 * The layout pass of one dispatcher: what has gone out of date, and when the
 * work of putting it right will run.
 *
 * An element that is invalidated registers here rather than laying itself out
 * on the spot.  Everything that changes in one turn of the message loop --
 * every property assignment, every child added, the resize that prompted them
 * -- is therefore settled by a single pass, instead of by one pass per change
 * with the half-finished results of each visible to the next.
 *
 * The pass runs at DispatcherPriority.render, above input, so a handler for
 * the click that follows a resize sees a tree that has already taken its new
 * shape.  WPF puts layout on the same band for the same reason.
 */
final class LayoutManager
{
   /**
    * The layout manager of a dispatcher, made on first use.
    *
    * A dispatcher belongs to one thread and a thread hosts one dispatcher, so
    * the slot is thread-local and needs no lock: everything that reaches it
    * has already verified it is on the owning thread.
    */
    static LayoutManager forDispatcher(shared(Dispatcher) dispatcher)
    {
        if (dispatcher is null)
            return null;

        // The identity check is not caution, it is the cleanup.  A dispatcher
        // that is shut down without ever having been pumped raises no
        // shutdown events but does vacate the thread, and the next object
        // built on that thread makes a fresh one.  Comparing identities lets a
        // stale manager fall away on its own; subscribing to shutdown instead
        // would leave the dispatcher holding the manager, and the manager
        // holding whole element trees, for as long as it lived.
        if (t_instance is null || t_instance._dispatcher !is dispatcher)
            t_instance = new LayoutManager(dispatcher);

        return t_instance;
    }

   /**
    * Settles everything outstanding now, rather than waiting for the pass the
    * dispatcher has queued.
    *
    * The whole thread is settled, not one subtree: layout is a property of the
    * tree, and an element cannot be sure of its own size while something above
    * it is still undecided.
    *
    * Called from inside a pass -- from an arrangeOverride, or from a handler
    * for the size change one caused -- it does nothing, because the pass it
    * would start is the pass it is being called from.
    */
    void updateLayout()
    {
        if (_inPass)
            return;

        // The queued pass is being done here and now.  abort() answers false
        // only when the pump has already claimed the operation, which on this
        // one thread means we are inside it -- and _inPass returned above.
        if (_pending !is null)
        {
            _pending.abort();
            _pending = null;
        }

        _inPass = true;
        scope (exit) _inPass = false;

        // A layout that threw leaves its elements dirty rather than half
        // arranged, and leaves nothing queued: the next invalidation starts
        // over from a state the manager can describe.
        scope (failure) discardQueues();

        int turns;

        while (_measureQueue.length || _arrangeQueue.length)
        {
            if (++turns > maxTurns)
            {
                // Cleared before the throw, or the application spends the rest
                // of its life failing the same pass.
                discardQueues();

                throw new Exception(
                    "Layout did not settle: something invalidated it again on "
                    ~ "every turn.  A handler for a size change that changes a "
                    ~ "size, or an arrangeOverride that invalidates what it has "
                    ~ "just arranged, is the usual cause.");
            }

            // Measure is drained to the bottom before anything is arranged.
            // Placing an element whose parent's desiredSize is stale means
            // placing it by a number that is about to change.
            while (_measureQueue.length)
            {
                auto batch = _measureQueue;
                _measureQueue = null;    // measuring invalidates more

                foreach (element; batch)
                {
                    // An ancestor's pass already answered for it.
                    if (element.isMeasureValid)
                        continue;

                    topmostDirtyMeasure(element).measureAsRoot();
                }
            }

            auto batch = _arrangeQueue;
            _arrangeQueue = null;

            foreach (element; batch)
            {
                if (element.isArrangeValid)
                    continue;

                topmostDirtyArrange(element).arrangeAsRoot();
            }

            // An arrange that invalidated a measure is picked up by the next
            // turn of this loop, with the measure queue drained again first.
        }
    }

   /**
    * Whether a pass is queued on the dispatcher and has not run yet.
    */
    @property bool isPassPending() const pure nothrow @nogc
    {
        return _pending !is null;
    }

package:
   /*
    * Records an element whose size has to be worked out again, and makes sure
    * a pass is coming.
    *
    * Repeats are not filtered out.  Being marked out-of-date and being queued
    * are separate things -- a pass that failed leaves elements marked with
    * nothing queued -- so an element registers on every invalidation rather
    * than only on the first, and one that is already up to date again by the
    * time the pass reaches it is skipped there instead.  What that costs is an
    * array slot and a comparison; what it buys is that no element can end up
    * marked and unreachable.
    */
    void enqueueMeasure(Element element)
    {
        element.verifyAccess();

        _measureQueue ~= element;
        schedulePass();
    }

    /// ditto
    void enqueueArrange(Element element)
    {
        element.verifyAccess();

        _arrangeQueue ~= element;
        schedulePass();
    }

private:
    this(shared(Dispatcher) dispatcher)
    {
        _dispatcher = dispatcher;
    }

    void schedulePass()
    {
        // The pass under way will reach it before it ends.
        if (_inPass)
            return;

        // Posting onto a closed queue throws, and an object being taken down
        // has every right to move a property on its way out.
        if (_dispatcher.hasShutdownStarted)
            return;

        // One pass outstanding at a time: what it settles is everything dirty
        // when it runs, not whatever was dirty when it was asked for.
        if (_pending !is null && _pending.status == OperationStatus.pending)
            return;

        _pending = _dispatcher.invokeAsync(&runPass, DispatcherPriority.render);
    }

    void runPass()
    {
        _pending = null;
        updateLayout();
    }

    void discardQueues()
    {
        _measureQueue = null;
        _arrangeQueue = null;
    }

   /*
    * The element a pass starts from: the highest one whose measure is out of
    * date, stopping at the first ancestor that is not.
    *
    * Stopping there is the point, rather than carrying on to look for another
    * dirty element further up.  An ancestor that is up to date would leave
    * measure at its own early-out and never reach down to the element that
    * needs the work; starting above it would skip exactly the subtree the
    * pass was called for.  An ancestor that is separately out of date has an
    * entry of its own and gets a start of its own.
    */
    static Element topmostDirtyMeasure(Element element)
    {
        auto top = element;

        while (top.parent !is null && !top.parent.isMeasureValid)
            top = top.parent;

        return top;
    }

    /// ditto
    static Element topmostDirtyArrange(Element element)
    {
        auto top = element;

        while (top.parent !is null && !top.parent.isArrangeValid)
            top = top.parent;

        return top;
    }

    // The same limit WPF uses, and for the same purpose: to end a pass that
    // will not converge with something a developer can read, rather than with
    // a hang.
    enum int maxTurns = 153;

    // Thread-local: one dispatcher per thread, so one manager per thread.
    static LayoutManager t_instance;

    shared(Dispatcher)          _dispatcher;
    Element[]                   _measureQueue;
    Element[]                   _arrangeQueue;
    shared(DispatcherOperation) _pending;
    bool                        _inPass;
}

version (unittest)
{
    import cherry.core.threading.testing;
    import cherry.platform.eventloop : ManualEventLoop;
    import cherry.platform.render : Rect, Size;
    import cherry.ui.event : RoutedEventArgs;

    import std.exception : assertThrown;

   /*
    * Writes down every pass it is put through, so a test can tell what the
    * layout reached from what it left alone.
    */
    private class Logger : Element
    {
        string name;
        string[]* log;

        this(string name, string[]* log)
        {
            this.name = name;
            this.log = log;
        }

        protected override Size measureOverride(Size availableSize)
        {
            *log ~= "measure:" ~ name;
            return super.measureOverride(availableSize);
        }

        protected override Size arrangeOverride(Size finalSize)
        {
            *log ~= "arrange:" ~ name;
            return super.arrangeOverride(finalSize);
        }
    }

   /*
    * Lays a tree out once and leaves everything up to date with nothing
    * queued, so that what a test does next is the only thing the pass has to
    * answer for.
    *
    * The measure and arrange establish the constraint by hand, since a root
    * with no parent would otherwise be sized against the nothing it was last
    * offered; updateLayout then takes away the entries that building the tree
    * put on the queue.
    */
    private void settle(Element root)
    {
        root.measure(Size(500, 400));
        root.arrange(Rect(0, 0, 500, 400));
        root.updateLayout();
    }
}

unittest
{
    // Everything that goes out of date between two turns of the loop is
    // settled by one pass, not by one pass each.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        string[] log;
        auto root = new Logger("root", &log);
        auto a = new Logger("a", &log);
        auto b = new Logger("b", &log);
        root.addChild(a);
        root.addChild(b);
        settle(root);

        auto manager = LayoutManager.forDispatcher(d);
        assert(!manager.isPassPending, "a settled tree asks for nothing");

        a.invalidateMeasure();
        assert(manager.isPassPending);

        b.invalidateMeasure();
        root.invalidateArrange();
        assert(manager.isPassPending, "still the one pass");

        log = null;
        pumpUntilIdle(d);

        assert(!manager.isPassPending);
        assert(root.isMeasureValid && a.isMeasureValid && b.isMeasureValid);
        assert(root.isArrangeValid && a.isArrangeValid && b.isArrangeValid);
        assert(log.length > 0, "and it did the work rather than dropping it");
    });
}

unittest
{
    // The pass runs at render priority: above input, so a click handler sees a
    // tree that has already taken its new shape, and below normal.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        string[] log;
        auto root = new Logger("root", &log);
        settle(root);

        root.invalidateMeasure();
        d.invokeAsync({ log ~= "input"; }, DispatcherPriority.input);
        d.invokeAsync({ log ~= "normal"; }, DispatcherPriority.normal);

        log = null;
        pumpUntilIdle(d);

        assert(log[0] == "normal");
        assert(log[1] == "measure:root");
        assert(log[$ - 1] == "input");
    });
}

unittest
{
    // A pass starts at the highest element that is out of date, not at the one
    // that happened to be invalidated: measuring a leaf means measuring
    // everything above it whose answer may have moved.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        string[] log;
        auto root = new Logger("root", &log);
        auto middle = new Logger("middle", &log);
        auto leaf = new Logger("leaf", &log);
        root.addChild(middle);
        middle.addChild(leaf);
        settle(root);

        leaf.invalidateMeasure();

        log = null;
        pumpUntilIdle(d);

        assert(log[0] == "measure:root", "the invalidation travelled up, so the pass starts up there");
        assert(log[1] == "measure:middle");
        assert(log[2] == "measure:leaf");
    });
}

unittest
{
    // And it stops at what is still up to date.  This is the test that proves
    // the early-outs are doing the work: the pass walks through the clean
    // sibling's parent and does not go into the sibling.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        string[] log;
        auto root = new Logger("root", &log);
        auto changed = new Logger("changed", &log);
        auto untouched = new Logger("untouched", &log);
        root.addChild(changed);
        root.addChild(untouched);
        settle(root);

        changed.invalidateMeasure();

        log = null;
        pumpUntilIdle(d);

        import std.algorithm : canFind;
        assert(log.canFind("measure:root"));
        assert(log.canFind("measure:changed"));
        assert(!log.canFind("measure:untouched"), "nothing asked it anything new");
    });
}

unittest
{
    // updateLayout settles the tree on the spot, and takes the queued pass
    // with it rather than leaving it to run again over nothing.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        string[] log;
        auto root = new Logger("root", &log);
        settle(root);

        root.invalidateMeasure();
        auto manager = LayoutManager.forDispatcher(d);
        assert(manager.isPassPending);

        log = null;
        root.updateLayout();

        assert(root.isMeasureValid && root.isArrangeValid);
        assert(log.length > 0);
        assert(!manager.isPassPending, "the queued pass was consumed, not duplicated");

        auto done = log.length;
        pumpUntilIdle(d);
        assert(log.length == done, "and nothing ran a second time");
    });
}

unittest
{
    // Nothing out of date is no work and no pass.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        string[] log;
        auto root = new Logger("root", &log);
        settle(root);

        log = null;
        root.updateLayout();

        assert(log == []);
        assert(!LayoutManager.forDispatcher(d).isPassPending);
    });
}

unittest
{
    // A handler for a size change may change something that needs laying out,
    // and is answered by the same pass rather than the next one.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        string[] log;
        auto root = new Logger("root", &log);
        auto child = new Logger("child", &log);
        root.addChild(child);
        settle(root);

        bool reacted;
        child.onSizeChanged ~= (Element sender, RoutedEventArgs args) {
            if (reacted)
                return;

            reacted = true;
            child.width = 40;
        };

        root.invalidateMeasure();
        root.arrange(Rect(0, 0, 320, 240));   // moves the child, so the handler fires

        assert(reacted);
        assert(!child.isMeasureValid, "the handler asked for more work");

        pumpUntilIdle(d);

        assert(child.isMeasureValid && child.isArrangeValid);
        assert(child.desiredSize.width == 40);
    });
}

unittest
{
    // Layout that will not converge ends with something a developer can read
    // rather than with a hang, and leaves nothing behind to fail on again.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        // Takes a different size every time it is arranged, so the size change
        // is always news and the handler below always runs.
        static class Restless : Element
        {
            float taken = 10;

            protected override Size arrangeOverride(Size finalSize)
            {
                taken = taken == 10 ? 20 : 10;
                return Size(taken, finalSize.height);
            }
        }

        auto restless = new Restless;
        settle(restless);

        // The cause the error message names: a handler for a size change that
        // asks for the layout that produced it to be done again.
        restless.onSizeChanged ~= (Element sender, RoutedEventArgs args) {
            restless.invalidateArrange();
        };

        restless.invalidateArrange();

        auto manager = LayoutManager.forDispatcher(d);
        assertThrown!Exception(manager.updateLayout());

        // The queues were emptied before the throw, so the next call is not
        // the same failure all over again.
        manager.updateLayout();
    });
}

unittest
{
    // A measureOverride that throws is reported, leaves its element out of
    // date rather than half settled, and does not wedge the manager.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        static class Brittle : Element
        {
            bool broken = true;

            protected override Size measureOverride(Size availableSize)
            {
                if (broken)
                    throw new Exception("measureOverride said no");

                return super.measureOverride(availableSize);
            }
        }

        auto brittle = new Brittle;
        brittle.broken = false;
        settle(brittle);

        auto manager = LayoutManager.forDispatcher(d);

        brittle.broken = true;
        brittle.invalidateMeasure();
        assertThrown!Exception(manager.updateLayout());
        assert(!brittle.isMeasureValid, "it is still waiting to be measured");

        // And it can be put back on the queue, which an element that were only
        // registered on the way from valid to invalid could not: it is already
        // invalid, and the failed pass took its entry with it.
        brittle.broken = false;
        brittle.invalidateMeasure();
        manager.updateLayout();

        assert(brittle.isMeasureValid);
    });
}

unittest
{
    // An object taken down with the application has every right to move a
    // property on its way out, and posting onto a closed queue would throw.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto root = new Element;
        settle(root);

        d.shutdown();

        root.invalidateMeasure();
        assert(!root.isMeasureValid, "it is marked, it just has nowhere to be settled");
    });
}

unittest
{
    // One manager per dispatcher, which on this design means one per thread.
    import core.thread : Thread;

    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto here = LayoutManager.forDispatcher(d);
        assert(here !is null);
        assert(LayoutManager.forDispatcher(d) is here, "and the same one every time");

        shared(LayoutManager) there;

        auto worker = new Thread({
            withDispatcher((shared(Dispatcher) other, ManualEventLoop otherLoop) {
                there = cast(shared) LayoutManager.forDispatcher(other);
            });
        });

        worker.start();
        worker.join();

        assert(there !is null);
        assert(cast(LayoutManager) there !is here, "a thread of its own lays out on its own");
    });
}

unittest
{
    // A dispatcher that has been replaced leaves its manager behind with it.
    // Nothing subscribes to shutdown to arrange that; the manager simply
    // checks which dispatcher it was made for.
    LayoutManager first;

    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        first = LayoutManager.forDispatcher(d);
    });

    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto second = LayoutManager.forDispatcher(d);
        assert(second !is first, "the stale one fell away on its own");
    });
}
