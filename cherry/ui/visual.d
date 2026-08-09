module cherry.ui.visual;

/*
 * This module must not import cherry.ui.layout, and the reason is worth
 * spelling out because the cost of getting it wrong arrives much later than
 * the mistake.
 *
 * element.d has a module constructor and is already in an import cycle with
 * layout.d -- one constructor in a cycle, which D allows.  If this module
 * imported layout.d as well, the cycle would close through it and element.d
 * and this module would be in the same one.  It would build today, because
 * there is no constructor here.  It would stop building on the day Visual
 * registers its first property -- Opacity, IsVisible, Clip, ZIndex are all
 * coming -- and it would stop by aborting every binary built against the
 * framework before main(), with a cyclic-dependency error naming neither the
 * import nor the property.
 *
 * So the one thing Visual wanted from layout.d, somewhere to put a repaint
 * request, goes behind the enqueueRepaint hook below instead.  Element
 * overrides it.  Imports then run strictly downwards -- layout.d imports this,
 * this imports nothing of cherry.ui but styledelement.d -- and a module
 * constructor here becomes a perfectly ordinary thing to add.
 */

import cherry.platform.render : DrawingContext, Matrix, Rect;
import cherry.ui.styledelement;

/**
 * The layer that has a place on the screen: where it was put, what it draws
 * there, and when that has to be drawn again.
 *
 * Everything above this is about what an object *is* -- its properties, its
 * styles, its data.  Everything below is about how big it wants to be and what
 * the user does to it.  This layer is only about pixels, and it is deliberately
 * possible to be one without being an Element: an adorner, an off-screen
 * surface and a cached bitmap are all visual and none of them is laid out.
 *
 * **The visual tree is a seam here, not storage.** visualParent,
 * visualChildCount and visualChild are what the render walk uses, and Element
 * answers all three from its one tree, because today the visual tree and the
 * element tree are the same tree.  They part company when control templates
 * arrive; the storage moves here then, and no caller changes.
 *
 * Still to come on this layer: Opacity, IsVisible, Clip and ZIndex as
 * properties, and hit-testing -- which is the next thing that will be built,
 * and which belongs here rather than on Element because what the mouse hits is
 * what is drawn.
 */
class Visual : StyledElement
{
   /**
    * The node above this one in the visual tree, or null at its top.
    *
    * Public and virtual for the same reason logicalParent is: it is the tree's
    * navigation API -- WPF spells it VisualTreeHelper.GetParent -- and a
    * `package` method in D is not virtual, so an override would be silently
    * ignored and every walk would stop at the first step.
    */
    @property Visual visualParent()
    {
        return null;
    }

   /**
    * The visual children, by count and index rather than as a range.
    *
    * WPF's shape, and it is the shape a seam wants: an implementation that
    * keeps no array -- a control building its children from a template on
    * demand -- can answer it, and one that does keep an array pays nothing.
    */
    @property size_t visualChildCount()
    {
        return 0;
    }

    /// ditto
    Visual visualChild(size_t index)
    {
        return null;
    }

   /**
    * The top of this visual's tree; the visual itself when it has none above
    * it.  For anything inside a window, the window.
    */
    @property Visual visualRoot()
    {
        Visual current = this;

        for (auto above = current.visualParent; above !is null; above = current.visualParent)
            current = above;

        return current;
    }

   /**
    * The rectangle this visual was last placed in, in its parent's coordinate
    * space.
    *
    * Written by whatever does the placing -- Element's arrange -- and read by
    * everything else.  It is the whole of what this layer knows about
    * geometry: the size an element asked for and the room it was offered are
    * one layer down.
    */
    @property Rect arrangedRect() const pure nothrow @nogc
    {
        return _arrangedRect;
    }

   /**
    * The region this visual draws into, in its own coordinate space.
    *
    * The default is its own bounds.  Nothing clips, so that default is a claim
    * rather than a fact: a visual drawing a shadow, a focus ring or an
    * overshooting glyph draws outside it and must widen this to say so.
    *
    * What the framework promises is that every pixel inside the region a
    * visual declares here, or names through invalidateVisual(Rect), is
    * repainted after that visual is invalidated -- and that the place it
    * occupied before it moved is repainted to the accuracy of this.
    *
    * What it does not promise is that nothing else is repainted; the region is
    * a lower bound.  Nor does it promise anything at all about drawing outside
    * the region declared here.  That is the price of having no clipping, and it
    * is paid by the visual that understated its reach.
    *
    * Only this visual's own drawing is meant, not its children's.  A repaint
    * redraws the whole tree and uses the region to decide which pixels reach
    * the screen, so a child inside the region is redrawn anyway and one outside
    * it did not change.
    *
    * Taken from the arranged rectangle and not from an element's ActualWidth
    * and ActualHeight: the two carry the same numbers by construction -- arrange
    * writes both from the same answer -- and only one of them exists at this
    * layer.
    */
    @property Rect renderBounds()
    {
        return Rect(0, 0, _arrangedRect.width, _arrangedRect.height);
    }

   /**
    * Renders this visual and its whole subtree in depth-first pre-order:
    * parents draw under their children.
    *
    * Each visual draws in a coordinate space of its own.  Its placement is
    * pushed onto the context as a translation before onRender runs, so a
    * visual draws itself at (0, 0) whatever its parent did with it, and its
    * children draw themselves at (0, 0) inside that.  Nobody offsets anybody by
    * hand, which is what lets a control be moved without a line of its drawing
    * code changing.
    *
    * The root is not a special case: it pushes its own placement like every
    * other visual.  A Window's placement is the client area's origin, so what
    * it pushes is a translation by nothing -- which is why a window needs no
    * exception rather than being one.
    *
    * Nothing is clipped.  A visual drawing outside its own bounds is seen doing
    * it, on purpose: overflow that shows is overflow that gets fixed.
    *
    * The push is undone on the way out whether onRender returns or throws, so
    * an exception leaving a visual finds the context as balanced as it left it.
    */
    final void renderSubtree(DrawingContext context)
    in {
        assert(context !is null);
    }
    do {
        context.pushTransform(Matrix.translation(_arrangedRect.x, _arrangedRect.y));
        scope (exit) context.popTransform();

        onRender(context);

        foreach (i; 0 .. visualChildCount)
            visualChild(i).renderSubtree(context);
    }

   /**
    * Asks for this visual to be drawn again, all of it -- which means the
    * region renderBounds declares.
    *
    * This does not travel up the tree.  Measuring travels because a parent's
    * answer is worked out from its children's, and drawing has no such
    * dependency.  Finding the surface to ask is the pass's job, not a mark left
    * on the way.
    */
    void invalidateVisual()
    {
        _visualDirty = true;
        enqueueRepaint(Rect.init, false);
    }

   /**
    * Asks for one region of this visual to be drawn again, in its own
    * coordinate space.
    *
    * The region is taken as given and is not narrowed to renderBounds: a visual
    * repainting something it draws outside itself -- a focus ring, a shadow --
    * is making an assertion, not a suggestion.  An empty region asks for
    * nothing at all, and does not even mark the visual.
    */
    void invalidateVisual(Rect region)
    {
        if (region.empty)
            return;

        _visualDirty = true;
        enqueueRepaint(region, true);
    }

   /**
    * Whether what is on the screen for this visual is up to date.
    */
    @property bool isVisualValid() const pure nothrow @nogc
    {
        return !_visualDirty;
    }

   /**
    * Asks the surface this visual is the top of to repaint a region, given in
    * this visual's own coordinate space.
    *
    * The default does nothing, and that is the whole of the right behaviour for
    * a tree with no surface under it: a pass that walked to the top and found
    * an ordinary Visual has found nowhere for pixels to go, and dropping the
    * request there is correct.  Window overrides this; a popup or an off-screen
    * surface would too.
    *
    * Called from inside a layout pass.  An override may only ask -- it must not
    * paint on the spot, and it must not lay anything out.
    */
    void repaintAsRoot(Rect region)
    {
    }

package:
   /*
    * Clears the visual mark.  The pass calls this as it takes a request off the
    * queue, before it works out where the region lands.
    */
    void markVisualValid() pure nothrow @nogc
    {
        _visualDirty = false;
    }

   /*
    * Where a region of this visual's own space falls in the space of the top of
    * its tree -- for a visual inside a window, the client area.
    *
    * renderSubtree pushes Matrix.translation(arrangedRect.x, arrangedRect.y)
    * for every visual from the root down, so the offset is the sum of those
    * origins over this visual and each of its ancestors.  This is that walk
    * with everything but the translation left out.  It includes this visual and
    * does not stop one short of it: the root pushes its own placement like
    * everybody else, which is what makes a Window need no exception.
    *
    * Unattributed, unlike the field reads around it.  It steps through the
    * virtual visualParent, and requiring `pure nothrow @nogc` of that would
    * bind every override the seam will ever have -- for a walk that runs once
    * per queued request rather than in any loop worth counting.
    */
    Rect toRootSpace(Rect region)
    {
        float dx = 0;
        float dy = 0;

        for (Visual v = this; v !is null; v = v.visualParent)
        {
            dx += v._arrangedRect.x;
            dy += v._arrangedRect.y;
        }

        return Rect(region.x + dx, region.y + dy, region.width, region.height);
    }

protected:
   /**
    * Draws this visual's own content, in its own coordinate space: (0, 0) is
    * its top left corner and it runs to the width and height of arrangedRect.
    *
    * arrangedRect says where this visual sits in its parent, and is not what to
    * draw against: renderSubtree has applied it already, and a visual that
    * reads it here draws itself twice as far from home as it meant to.
    *
    * The default draws nothing; controls override this.
    */
    void onRender(DrawingContext context)
    {
    }

   /**
    * Hands a repaint request to whatever collects them, or drops it.
    *
    * The default drops it, which is the honest answer for a visual with no
    * layout pass behind it -- the same answer repaintAsRoot gives a tree with
    * no surface over it.  Element overrides this to reach the pass.
    *
    * It exists so that this module never has to name the layout manager; the
    * banner at the top of the file is about what that would cost.
    */
    void enqueueRepaint(Rect region, bool hasRegion)
    {
    }

   /**
    * Where this visual was placed, in its parent's coordinate space.
    *
    * Protected rather than private because the layer that does the arranging
    * sits below this one and has to write it.  Read another instance's through
    * the public arrangedRect.
    */
    Rect _arrangedRect;

private:
    // An element that has never been drawn is out of date by definition, so the
    // mark starts raised and only a drain lowers it.
    bool _visualDirty = true;
}

version (unittest)
{
    import cherry.platform.render : RecordingContext;

   /*
    * A visual with a tree of its own and nothing else -- no layout, no
    * properties, no element.
    *
    * That is the whole point of it.  element.d tests this layer the way it is
    * actually used, through margins and alignments and a measure pass, and
    * those tests stay there because they need all of it.  What they cannot
    * show is that the layer stands on its own: that renderSubtree walks the
    * seam rather than somebody's `_children`, and that a repaint request from
    * a visual with no pass under it goes nowhere instead of somewhere wrong.
    *
    * It also has to be written here rather than there, because visual.d must
    * not import element.d -- not even under version(unittest).  The banner at
    * the top of the file is about exactly that import.
    */
    private class Node : Visual
    {
        string tag;
        Node   above;
        Node[] below;

        /// Every repaint this node was asked to pass on, in order.
        Rect[] requests;
        bool[] regionful;

        this(string tag = null, Rect placement = Rect.init)
        {
            this.tag = tag;
            _arrangedRect = placement;
        }

        void add(Node child)
        {
            below ~= child;
            child.above = this;
        }

        override @property Visual visualParent() { return above; }
        override @property size_t visualChildCount() { return below.length; }
        override Visual visualChild(size_t index) { return below[index]; }

        protected override void onRender(DrawingContext context)
        {
            renderLog ~= tag;
        }

        protected override void enqueueRepaint(Rect region, bool hasRegion)
        {
            requests ~= region;
            regionful ~= hasRegion;
        }
    }

    private string[] renderLog;
}

unittest
{
    // A Visual with nothing under it: no tree, no surface, and every answer
    // still well defined.
    auto lone = new Visual;

    assert(lone.visualParent is null);
    assert(lone.visualChildCount == 0);
    assert(lone.visualRoot is lone, "the top of a tree of one");
    assert(lone.arrangedRect == Rect.init);
    assert(lone.renderBounds == Rect.init);
    assert(!lone.isVisualValid, "never drawn, so out of date by definition");

    // Neither of these has anywhere to go, and neither is an error.
    lone.repaintAsRoot(Rect(0, 0, 10, 10));
    lone.invalidateVisual();

    lone.renderSubtree(new RecordingContext);
}

unittest
{
    // The render walk goes through the seam, in depth-first pre-order, so
    // parents draw under their children.
    //
    // Nothing here has an element tree.  A renderSubtree that reached for a
    // `_children` field instead of asking would visit nothing at all.
    auto root = new Node("root");
    auto a = new Node("a");
    auto b = new Node("b");
    auto c = new Node("c");
    root.add(a);
    root.add(b);
    a.add(c);

    renderLog = null;
    root.renderSubtree(new RecordingContext);
    assert(renderLog == ["root", "a", "c", "b"]);
}

unittest
{
    // Each visual draws in a space of its own, and the walk composes the
    // placements down the chain.  Read off the recorder, not worked out here.
    auto root = new Node("root", Rect(10, 20, 200, 100));
    auto inner = new Node("inner", Rect(5, 5, 100, 50));
    root.add(inner);

    auto context = new RecordingContext;
    renderLog = null;
    root.renderSubtree(context);

    assert(context.depth == 0, "the walk left the stack as it found it");
    assert(inner.toRootSpace(inner.renderBounds) == Rect(15, 25, 100, 50),
           "its own origin plus every origin above it");
    assert(root.toRootSpace(root.renderBounds) == Rect(10, 20, 200, 100),
           "the root pushes its own placement too, which is why a window is no exception");

    // And the walk to the top goes through the same seam.
    assert(inner.visualRoot is root);
    assert(root.visualRoot is root);
}

unittest
{
    // The mark and the request are two different things, and both halves of
    // invalidateVisual are worth watching.
    auto node = new Node;
    node.markVisualValid();
    assert(node.isVisualValid);

    node.invalidateVisual();
    assert(!node.isVisualValid);
    assert(node.requests.length == 1);
    assert(!node.regionful[0], "no region named, so the pass will ask renderBounds");

    node.markVisualValid();
    node.invalidateVisual(Rect(1, 2, 30, 40));
    assert(!node.isVisualValid);
    assert(node.requests[1] == Rect(1, 2, 30, 40) && node.regionful[1],
           "taken as given, and not narrowed to renderBounds");

    // An empty region asks for nothing at all, and does not even mark.
    node.markVisualValid();
    node.invalidateVisual(Rect(5, 5, 0, 10));
    assert(node.isVisualValid);
    assert(node.requests.length == 2, "nothing was passed on either");
}
