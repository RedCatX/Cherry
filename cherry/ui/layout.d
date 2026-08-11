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
import cherry.platform.render : Rect;
import cherry.ui.element;
import cherry.ui.visual : Visual;

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
final class LayoutManager : DispatcherObject
{
   /**
    * The layout manager of the calling thread, made on first use.
    *
    * A dispatcher belongs to one thread and a thread hosts one dispatcher, so
    * the slot is thread-local and needs no lock: everything that reaches it is
    * already on the owning thread.  Being a DispatcherObject is what makes
    * that true rather than merely intended -- the manager binds to the
    * dispatcher of the thread that built it and cannot be handed another.
    *
    * Null on a thread with no dispatcher, which is a thread with nothing to
    * schedule a pass on.  That is not the same as asking for one: an object
    * moving a property on its way out of a shutdown would otherwise raise a
    * whole new dispatcher, message-only window and all, to record work that
    * will never run.
    */
    static LayoutManager forCurrentThread()
    {
        auto current = Dispatcher.currentOrNull;

        if (current is null)
            return null;

        // The identity check is not caution, it is the cleanup.  A dispatcher
        // that is shut down without ever having been pumped raises no
        // shutdown events but does vacate the thread, and the next object
        // built on that thread makes a fresh one.  Comparing identities lets a
        // stale manager fall away on its own; subscribing to shutdown instead
        // would leave the dispatcher holding the manager, and the manager
        // holding whole element trees, for as long as it lived.
        if (t_instance is null || t_instance.dispatcher !is current)
            t_instance = new LayoutManager;

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

        // Everything now has a size and a place; the surfaces are told which
        // parts of them changed.  One pass in this order is what makes "laid
        // out, then repainted" true by construction rather than by whoever
        // remembered to do both.
        //
        // After the loop and not inside it, and deliberately after the
        // scope(failure) above: a pass that threw leaves the tree half
        // arranged -- some elements placed, some not -- and asking a window to
        // repaint that is asking it to show half a frame.  The elements keep
        // their marks, because only a successful drain clears them, so the
        // next invalidation brings them back.  What is lost is one repaint,
        // not a window.
        flushVisuals();
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

   /*
    * Records a visual that has to be drawn again, either all of it -- which
    * the pass reads off its renderBounds when it gets there, so a visual may
    * still change its mind -- or one region of it named now.
    *
    * Typed Visual and not Element, unlike the two queues above.  Being drawn
    * and being laid out are two different layers, and the repaint queue is the
    * one that can hold something with no layout at all.
    */
    void enqueueVisual(Visual visual)
    {
        visual.verifyAccess();

        _visualQueue ~= VisualRequest(visual, Rect.init, false);
        schedulePass();
    }

    /// ditto
    void enqueueVisual(Visual visual, Rect region)
    {
        visual.verifyAccess();

        _visualQueue ~= VisualRequest(visual, region, true);
        schedulePass();
    }

private:
    void schedulePass()
    {
        // The pass under way will reach it before it ends.
        if (_inPass)
            return;

        // Posting onto a closed queue throws, and an object being taken down
        // has every right to move a property on its way out.
        if (dispatcher.hasShutdownStarted)
            return;

        // One pass outstanding at a time: what it settles is everything dirty
        // when it runs, not whatever was dirty when it was asked for.
        if (_pending !is null && _pending.status == OperationStatus.pending)
            return;

        _pending = dispatcher.invokeAsync(&runPass, DispatcherPriority.render);
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
        _visualQueue = null;
    }

   /*
    * Turns the outstanding repaint requests into one ask per surface.
    *
    * A counted loop rather than a single sweep, because renderBounds is
    * element code and may invalidate again -- and schedulePass() will not
    * help there.  It bails while a pass is running on the grounds that the
    * pass will reach the work before it ends, which is true of the measure
    * and arrange queues, whose loop re-checks, and false of anything appended
    * after this drain has taken its snapshot.
    */
    void flushVisuals()
    {
        int flushes;

        while (_visualQueue.length)
        {
            if (++flushes > maxTurns)
            {
                discardQueues();

                throw new Exception(
                    "The render queue did not settle: something asked for a "
                    ~ "repaint again on every turn.  A renderBounds that "
                    ~ "invalidates is the usual cause.");
            }

            auto batch = _visualQueue;
            _visualQueue = null;

            RootRegion[] roots;

            foreach (request; batch)
            {
                auto visual = request.visual;

                // No skip on the mark, unlike the measure drain -- and this is
                // the difference, not an oversight.  An element invalidated
                // twice in one turn over two regions that do not overlap would
                // have the second silently dropped, because the first entry
                // cleared the mark.  Every entry contributes; duplicates union
                // to the same answer, and what that costs is a rectangle.
                immutable own = request.hasRegion ? request.region : visual.renderBounds;

                visual.markVisualValid();

                if (own.empty)
                    continue;

                // Cut down by every clipping ancestor on the way up, which is
                // the first time a declared region is checked against anything
                // rather than taken at its word.  Nothing was lying: a region
                // outside a clip really was going to be drawn there, until an
                // ancestor said that nothing of its children reaches outside
                // itself.  Repainting it would be repainting the ancestor's
                // background for no reason.
                immutable region = visual.clippedToRootSpace(own);

                if (region.empty)
                    continue;

                auto root = visual.visualRoot;

                // A linear scan and not an associative array: the distinct
                // roots on one dispatcher are its windows, of which there are
                // one or two.
                bool merged;

                foreach (ref entry; roots)
                {
                    if (entry.root is root)
                    {
                        entry.region = entry.region.unite(region);
                        merged = true;
                        break;
                    }
                }

                if (!merged)
                    roots ~= RootRegion(root, region);
            }

            // A visual whose tree has no surface over it walks up to an
            // ordinary Visual, whose repaintAsRoot does nothing.  The request
            // evaporates, which is the same answer markLayoutDirty gives a
            // detached element for layout.
            foreach (entry; roots)
                entry.root.repaintAsRoot(entry.region);
        }
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

   /*
    * A repaint asked for but not yet passed on.  Without a region, the pass
    * asks the element for its renderBounds when it gets there.
    */
    static struct VisualRequest
    {
        Visual  visual;
        Rect    region;
        bool    hasRegion;
    }

    /// One surface and everything asked of it this turn.
    static struct RootRegion
    {
        Visual  root;
        Rect    region;
    }

    Element[]                   _measureQueue;
    Element[]                   _arrangeQueue;
    // Never part of the while condition above: a repaint is not layout work
    // and must not keep the pass spinning.
    VisualRequest[]             _visualQueue;
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

   /*
    * A stand-in for a window: the top of a tree that has somewhere to put
    * pixels, recording what it was asked to repaint.
    *
    * An Element and not a Window, and it has to be.  This module may not
    * import cherry.ui.window -- not even under version(unittest) -- because
    * window.d already imports this one from its own tests, and both it and
    * element.d have module constructors: the cycle would abort every binary
    * before main.  The banner at the top of this file is about exactly this.
    */
    private class Surface : Element
    {
        Rect[] repaints;

        override void repaintAsRoot(Rect region)
        {
            repaints ~= region;
        }
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

        auto manager = LayoutManager.forCurrentThread();
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
        auto manager = LayoutManager.forCurrentThread();
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
        assert(!LayoutManager.forCurrentThread().isPassPending);
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

        auto manager = LayoutManager.forCurrentThread();
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

        auto manager = LayoutManager.forCurrentThread();

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

        // And no dispatcher was conjured to hold the news.  Asking for the
        // manager through Dispatcher.current would have built a fresh one,
        // message-only window and all, on the way out of a shutdown.
        assert(LayoutManager.forCurrentThread() is null);
        assert(Dispatcher.currentOrNull is null);
    });
}

unittest
{
    // The manager belongs to the thread that built it and cannot be handed
    // another dispatcher -- which is what being a DispatcherObject buys.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto manager = LayoutManager.forCurrentThread();

        assert(manager.dispatcher is d);
        manager.verifyAccess();
        assert(manager.checkAccess());
    });
}

unittest
{
    // One manager per dispatcher, which on this design means one per thread.
    import core.thread : Thread;

    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto here = LayoutManager.forCurrentThread();
        assert(here !is null);
        assert(LayoutManager.forCurrentThread() is here, "and the same one every time");

        shared(LayoutManager) there;

        auto worker = new Thread({
            withDispatcher((shared(Dispatcher) other, ManualEventLoop otherLoop) {
                there = cast(shared) LayoutManager.forCurrentThread();
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
        first = LayoutManager.forCurrentThread();
    });

    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto second = LayoutManager.forCurrentThread();
        assert(second !is first, "the stale one fell away on its own");
    });
}

unittest
{
    // Two elements out of date, one ask, and the region covers both.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto surface = new Surface;
        auto a = new Element;
        auto b = new Element;
        surface.addChild(a);
        surface.addChild(b);

        a.width = 40;
        a.height = 20;
        a.horizontalAlignment = HorizontalAlignment.left;
        a.verticalAlignment = VerticalAlignment.top;

        b.width = 30;
        b.height = 10;
        b.horizontalAlignment = HorizontalAlignment.right;
        b.verticalAlignment = VerticalAlignment.bottom;

        settle(surface);
        surface.repaints = null;

        a.invalidateVisual();
        b.invalidateVisual();
        surface.updateLayout();

        assert(surface.repaints.length == 1, "two asks, one repaint");

        // a sits at the top left and b at the bottom right, so the region
        // spans the pair.
        assert(surface.repaints[0] == a.toRootSpace(a.renderBounds)
                                       .unite(b.toRootSpace(b.renderBounds)));
    });
}

unittest
{
    // A clipping ancestor cuts the region down, because what it clipped away
    // was never going to be drawn and does not have to be drawn again.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto surface = new Surface;
        auto frame = new Element;
        auto child = new Element;
        surface.addChild(frame);
        frame.addChild(child);

        frame.width = 100;
        frame.height = 100;
        frame.horizontalAlignment = HorizontalAlignment.left;
        frame.verticalAlignment = VerticalAlignment.top;

        child.width = 400;
        child.height = 400;
        child.horizontalAlignment = HorizontalAlignment.left;
        child.verticalAlignment = VerticalAlignment.top;

        settle(surface);
        surface.repaints = null;

        child.invalidateVisual();
        surface.updateLayout();

        assert(surface.repaints[0] == Rect(0, 0, 400, 400), "nothing clips, so all of it");

        frame.clipToBounds = true;
        settle(surface);
        surface.repaints = null;

        child.invalidateVisual();
        surface.updateLayout();

        assert(surface.repaints[0] == Rect(0, 0, 100, 100), "cut to the frame");
    });
}

unittest
{
    // And a region clipped away entirely asks for nothing at all -- the visual
    // is still taken off the queue and still marked valid, because it was
    // asked and answered.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto surface = new Surface;
        auto frame = new Element;
        auto child = new Element;
        surface.addChild(frame);
        frame.addChild(child);

        frame.width = 100;
        frame.height = 100;
        frame.horizontalAlignment = HorizontalAlignment.left;
        frame.verticalAlignment = VerticalAlignment.top;
        frame.clipToBounds = true;

        settle(surface);
        surface.repaints = null;

        // Well outside the frame, in the child's own space.
        child.invalidateVisual(Rect(500, 500, 20, 20));
        assert(!child.isVisualValid);

        surface.updateLayout();

        assert(surface.repaints.length == 0, "drawn nowhere, so redrawn nowhere");
        assert(child.isVisualValid, "asked, answered, and off the queue");
    });
}

unittest
{
    // Laid out first, repainted last -- the whole reason the two share a pass.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        static string[] log;
        log = null;

        static class Noisy : Surface
        {
            protected override Size arrangeOverride(Size finalSize)
            {
                log ~= "arrange";
                return super.arrangeOverride(finalSize);
            }

            override void repaintAsRoot(Rect region)
            {
                log ~= "repaint";
                super.repaintAsRoot(region);
            }
        }

        auto surface = new Noisy;
        surface.addChild(new Element);

        settle(surface);
        log = null;

        // Both kinds of work outstanding, settled by one pass: the placing
        // happens in the loop, the asking after it.
        surface.invalidateMeasure();
        surface.invalidateVisual();
        surface.updateLayout();

        assert(log.length >= 2);
        assert(log[0] == "arrange");
        assert(log[$ - 1] == "repaint", "the ask comes after the placing, always");
    });
}

unittest
{
    // A named region is used as given, even one reaching outside the element.
    // Nothing narrows it to renderBounds: an element repainting a focus ring
    // it draws beyond its own box is asserting, not suggesting.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto surface = new Surface;
        auto child = new Element;
        surface.addChild(child);

        child.width = 40;
        child.height = 20;
        child.horizontalAlignment = HorizontalAlignment.left;
        child.verticalAlignment = VerticalAlignment.top;

        settle(surface);
        surface.repaints = null;

        child.invalidateVisual(Rect(-5, -5, 60, 40));
        surface.updateLayout();

        assert(surface.repaints.length == 1);
        assert(surface.repaints[0] == Rect(-5, -5, 60, 40), "as given, not clipped to the child");
    });
}

unittest
{
    // An element that says it draws wider than it is gets what it asked for.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        static class Overflowing : Element
        {
            override @property Rect renderBounds()
            {
                // A shadow four units out on every side.
                return Rect(-4, -4, actualWidth + 8, actualHeight + 8);
            }
        }

        auto surface = new Surface;
        auto child = new Overflowing;
        surface.addChild(child);

        child.width = 40;
        child.height = 20;
        child.horizontalAlignment = HorizontalAlignment.left;
        child.verticalAlignment = VerticalAlignment.top;

        settle(surface);
        surface.repaints = null;

        child.invalidateVisual();
        surface.updateLayout();

        assert(surface.repaints[0] == Rect(-4, -4, 48, 28));
    });
}

unittest
{
    // An empty region asks for nothing, and does not even mark the element.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto surface = new Surface;
        auto child = new Element;
        surface.addChild(child);

        settle(surface);

        // Drained once, so the mark it was born with is gone and what happens
        // next is only what this test asks for.
        child.invalidateVisual();
        surface.updateLayout();
        assert(child.isVisualValid);
        surface.repaints = null;

        child.invalidateVisual(Rect(10, 10, 0, 50));
        assert(child.isVisualValid, "nothing was asked, so nothing is out of date");

        surface.updateLayout();
        assert(surface.repaints.length == 0);
    });
}

unittest
{
    // Two surfaces on one dispatcher are asked separately, each for its own.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto first = new Surface;
        auto second = new Surface;
        auto a = new Element;
        auto b = new Element;
        first.addChild(a);
        second.addChild(b);

        settle(first);
        settle(second);
        first.repaints = null;
        second.repaints = null;

        a.invalidateVisual();
        b.invalidateVisual();
        first.updateLayout();

        assert(first.repaints.length == 1);
        assert(second.repaints.length == 1, "the other surface heard about its own");
    });
}

unittest
{
    // A pass that threw drops the repaint and keeps the mark, so the next
    // invalidation brings it back rather than losing it for good.
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

        auto surface = new Surface;
        auto brittle = new Brittle;
        surface.addChild(brittle);

        assertThrown(settle(surface));
        assert(surface.repaints.length == 0, "a half-arranged tree is not shown");
        assert(!brittle.isVisualValid, "and it is still on the books");

        brittle.broken = false;
        brittle.invalidateMeasure();
        brittle.invalidateVisual();
        settle(surface);

        assert(surface.repaints.length == 1);
    });
}

unittest
{
    // A tree with no surface over it: the ask walks up, finds an ordinary
    // element, and evaporates -- the same answer layout gives a detached one.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto root = new Element;
        auto child = new Element;
        root.addChild(child);

        settle(root);

        child.invalidateVisual();
        root.updateLayout();

        assert(child.isVisualValid, "asked, answered by nobody, and off the queue");
    });
}

unittest
{
    // After a shutdown there is nothing to schedule on, so an invalidation
    // marks its element and stops.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto surface = new Surface;
        settle(surface);

        d.shutdown();

        surface.invalidateVisual();
        assert(!surface.isVisualValid, "marked, it just has nowhere to be settled");
        assert(LayoutManager.forCurrentThread() is null);
    });
}

unittest
{
    // An element that moved is asked for twice over: where it went, and where
    // it was.  Without the second, it would stay on the screen in both places.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto surface = new Surface;
        auto child = new Element;
        surface.addChild(child);

        child.width = 50;
        child.height = 20;
        child.horizontalAlignment = HorizontalAlignment.left;
        child.verticalAlignment = VerticalAlignment.top;

        settle(surface);
        assert(child.arrangedRect == Rect(0, 0, 50, 20));
        surface.repaints = null;

        child.horizontalAlignment = HorizontalAlignment.right;
        surface.updateLayout();

        assert(child.arrangedRect == Rect(450, 0, 50, 20));
        assert(surface.repaints.length == 1);
        assert(surface.repaints[0] == Rect(0, 0, 500, 20),
               "from where it was to where it went, in one region");
    });
}

unittest
{
    // Arranging something back where it already was asks for nothing.  This
    // is what stops the queue from being busy on every frame.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto surface = new Surface;
        auto child = new Element;
        surface.addChild(child);

        settle(surface);
        surface.repaints = null;

        child.invalidateArrange();
        surface.updateLayout();

        assert(child.isArrangeValid, "it was arranged");
        assert(surface.repaints.length == 0, "and it landed where it already was");
    });
}

unittest
{
    // arrange() writes ActualWidth and ActualHeight through the property
    // system, so onPropertyChanged fires on every pass that changes a size.
    // Neither carries affectsRender, and this is what would go wrong if one
    // ever did: the queue would re-arm from inside the pass, every frame.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto surface = new Surface;
        auto child = new Element;
        surface.addChild(child);

        settle(surface);
        surface.repaints = null;

        // A real change of size, which does move the child.
        child.width = 120;
        child.height = 60;
        surface.updateLayout();
        assert(surface.repaints.length == 1);

        surface.repaints = null;
        surface.updateLayout();
        assert(surface.repaints.length == 0, "and then it is quiet");
    });
}

unittest
{
    // A child leaving takes its pixels with it, so the parent asks for the
    // place it was: the child cannot, having just lost the tree the region
    // was expressed in.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto surface = new Surface;
        auto child = new Element;
        surface.addChild(child);

        child.width = 50;
        child.height = 20;
        child.horizontalAlignment = HorizontalAlignment.left;
        child.verticalAlignment = VerticalAlignment.top;

        settle(surface);
        assert(child.arrangedRect == Rect(0, 0, 50, 20));
        surface.repaints = null;

        surface.removeChild(child);
        surface.updateLayout();

        assert(surface.repaints.length == 1);
        assert(surface.repaints[0] == Rect(0, 0, 50, 20), "exactly the hole it left");
    });
}

unittest
{
    // A child joining has never been drawn here, whatever it did before --
    // and that is not covered by arranging, which asks only when the
    // placement changes.
    withDispatcher((shared(Dispatcher) d, ManualEventLoop loop) {
        auto surface = new Surface;
        auto child = new Element;

        settle(surface);
        surface.repaints = null;

        surface.addChild(child);
        assert(!child.isVisualValid);

        surface.updateLayout();
        assert(surface.repaints.length == 1);
    });
}
