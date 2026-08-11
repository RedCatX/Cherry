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
 * registers its first property, and it would stop by aborting every binary
 * built against the framework before main(), with a cyclic-dependency error
 * naming neither the import nor the property.
 *
 * So the one thing Visual wanted from layout.d, somewhere to put a repaint
 * request, goes behind the enqueueRepaint hook below instead.  Element
 * overrides it.  Imports then run strictly downwards -- layout.d imports this,
 * this imports nothing of cherry.ui but styledelement.d -- and a module
 * constructor here becomes a perfectly ordinary thing to add.
 *
 * Which it now is: the five properties below are registered from one.  It is
 * worth noticing that this is exactly the day the paragraph above was written
 * for, and that nothing had to be rearranged to reach it.
 */

import cherry.core.property;
import cherry.core.rtti;
import cherry.core.value;
import cherry.platform.render : DrawingContext, Matrix, Point, Rect;
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
 * **What this layer decides is what reaches the screen and in what order.**
 * visible says whether there is anything here at all, opacity how much of it
 * comes through, clipToBounds what is cut away at the edges, zIndex which
 * sibling is in front, and isHitTestVisible whether the mouse may find it.
 * Hit-testing lives here rather than on Element for the same reason all five
 * do: what the mouse hits is what is drawn, and drawing is what this layer is.
 *
 * Still to come: an arbitrary clip rather than the bounds, RenderTransform, and
 * caching a subtree as a bitmap.  All three want a geometry or a surface of
 * their own, which is why none of them is here yet.
 */
class Visual : StyledElement
{
    shared static this()
    {
        // No affectsRender: turning a visual deaf to the mouse changes nothing
        // about the pixels it puts on the screen.
        PropertyMetadata hitTestMeta;
        hitTestMeta.defaultValue = Value(true);

        isHitTestVisibleProperty = Property.register("isHitTestVisible",
            getRtti!bool(), getRtti!Visual(), hitTestMeta);

        // affectsMeasure and not affectsParentMeasure: this changes what the
        // element itself measures to, and invalidateMeasure walks up from there
        // on its own.  affectsParentMeasure is for the other case -- a property
        // that leaves its element's own size alone and changes only what the
        // parent does with it, which is what Grid.row carries it for.
        //
        // A Visual with no layout under it ignores both, the same way it
        // already ignores affectsRender.
        PropertyMetadata visibleMeta;
        visibleMeta.defaultValue = Value(true);
        visibleMeta.affectsRender = true;
        visibleMeta.affectsMeasure = true;

        visibleProperty = Property.register("visible",
            getRtti!bool(), getRtti!Visual(), visibleMeta);

        // Off, so that overflow is seen rather than quietly cut away.  A
        // container that means to hold its content in says so; one that did not
        // mean to overflow finds out that it does.  WPF's ClipToBounds and
        // Avalonia's both default the same way.
        //
        // Only affectsRender: what a visual clips away changes its pixels and
        // nothing about its size or its parent's.
        PropertyMetadata clipMeta;
        clipMeta.defaultValue = Value(false);
        clipMeta.affectsRender = true;

        clipToBoundsProperty = Property.register("clipToBounds",
            getRtti!bool(), getRtti!Visual(), clipMeta);

        // affectsRender on the visual itself and nothing about its parent.
        // Raising a child above its sibling changes pixels only where the two
        // overlap, and that is inside this child's own bounds -- which is what
        // its own repaint request covers.
        PropertyMetadata zMeta;
        zMeta.defaultValue = Value(0);
        zMeta.affectsRender = true;

        zIndexProperty = Property.register("zIndex",
            getRtti!int(), getRtti!Visual(), zMeta);

        // Opaque, which is what everything is until somebody fades it.
        PropertyMetadata opacityMeta;
        opacityMeta.defaultValue = Value(1.0f);
        opacityMeta.affectsRender = true;

        opacityProperty = Property.register("opacity",
            getRtti!float(), getRtti!Visual(), opacityMeta, &isFraction);
    }

    static immutable(Property) isHitTestVisibleProperty;
    static immutable(Property) visibleProperty;
    static immutable(Property) clipToBoundsProperty;
    static immutable(Property) zIndexProperty;
    static immutable(Property) opacityProperty;

   /**
    * Whether the mouse can find this visual -- and, when it cannot, anything
    * below it either.
    *
    * The whole subtree goes with it, which is what makes this mean "clicks pass
    * through this layer" rather than "this one node is skipped".  WPF works the
    * same way, and the alternative would be strange: a decoration drawn over a
    * control would let the mouse through itself and then catch it on the label
    * inside it.
    *
    * This is the answer to "it draws but takes no input" -- a property and not a
    * position in the class hierarchy, because the same element wants to be
    * ordinary in every other respect, and a parallel branch of types for each
    * "the same, but deaf" would be a poor trade.
    *
    * It says nothing about being seen.  A visual with this false is drawn
    * exactly as before; `visible` below is the other question.
    */
    @property bool isHitTestVisible() const
    {
        return getValue(isHitTestVisibleProperty).get!bool;
    }

    /// ditto
    @property void isHitTestVisible(bool value)
    {
        setValue(isHitTestVisibleProperty, Value(value));
    }

   /**
    * Whether this visual is there at all: drawn, findable by the mouse, and
    * taking up room.
    *
    * False collapses it.  It is not drawn, the mouse cannot find it, and -- for
    * anything that is also an Element -- it is not measured, so it costs its
    * parent nothing and its neighbours close up over the space it had.
    *
    * The whole subtree goes with it, a child whose own `visible` is true
    * included: what is switched off is the layer, not the node.  That is the
    * same rule isHitTestVisible follows, and it is the only rule that makes
    * hiding a panel mean what everybody expects it to mean.
    *
    * Not `isVisible`.  The `is` reads as a question about a state being
    * observed -- isPressed, isFocused, isMouseOver are all answers the
    * framework writes -- and this is not one of those: it is an attribute, set
    * by whoever is building the window.
    */
    @property bool visible() const
    {
        return getValue(visibleProperty).get!bool;
    }

    /// ditto
    @property void visible(bool value)
    {
        setValue(visibleProperty, Value(value));
    }

   /**
    * Whether this visual holds its drawing, and its children's, inside its own
    * bounds.
    *
    * Off by default: a visual that draws outside itself is seen doing it, which
    * is how overflow gets noticed instead of being silently trimmed.  Turning
    * it on is a container saying that what it holds is its own business --
    * which is what anything that scrolls has to say before it can scroll.
    *
    * The bounds are arrangedRect's size at the origin, not renderBounds.  The
    * two differ exactly where a visual claims to draw outside its box, and
    * agreeing with that claim here would make the property do nothing in the
    * one case it was asked for.
    *
    * It cuts input as well as pixels: what cannot be seen because this clipped
    * it away cannot be clicked either.  That is the assumption the search in
    * hitTest is finally allowed to make -- without a clip it has to walk into
    * children that lie outside their parent, because they really are drawn out
    * there.
    */
    @property bool clipToBounds() const
    {
        return getValue(clipToBoundsProperty).get!bool;
    }

    /// ditto
    @property void clipToBounds(bool value)
    {
        setValue(clipToBoundsProperty, Value(value));
    }

   /**
    * Which of its siblings this visual is drawn over: higher is nearer the
    * viewer, and equal means the order they sit in the tree.
    *
    * Only siblings are compared.  A child never leaves its parent's layer,
    * whatever number it carries -- so a zIndex of a thousand raises something
    * above the things beside it and never above the panel next door.  WPF's
    * Panel.ZIndex and Avalonia's Visual.ZIndex both work this way, and the
    * alternative -- one order across the whole tree -- would mean a control
    * could be split in half by a stranger drawing between its parts.
    *
    * The mouse follows the same order backwards, because what is on top is
    * what a click lands on.
    *
    * Ordinary trees leave this at zero, and the walk that draws them notices
    * and does not sort at all.
    */
    @property int zIndex() const
    {
        return getValue(zIndexProperty).get!int;
    }

    /// ditto
    @property void zIndex(int value)
    {
        setValue(zIndexProperty, Value(value));
    }

   /**
    * How much of this visual, and of everything under it, reaches the screen:
    * 1 is all of it, 0 is none.
    *
    * The subtree is faded as one picture and not one visual at a time, so two
    * overlapping children at half opacity show the background through the pair
    * rather than each other through the overlap.  That is what makes fading a
    * panel look like fading a panel.
    *
    * **Zero is WPF's Hidden.** Nothing is drawn and nothing can be clicked, and
    * the room the visual takes is untouched -- its neighbours stay where they
    * are and the hole stays open.  `visible = false` is the other one: it takes
    * the room away as well.  Between them they are the three states WPF spells
    * with an enumeration, arrived at from two properties that were each wanted
    * anyway.
    *
    * Anything below one costs a layer -- an off-screen surface and a second
    * pass over those pixels -- and one costs nothing at all, which is the case
    * the walk checks for first.
    *
    * Values outside 0 to 1 are refused rather than clamped.  There is no
    * reading of "opacity 2" that anybody meant, and a write that is quietly
    * corrected is a bug that surfaces somewhere else.
    */
    @property float opacity() const
    {
        return getValue(opacityProperty).get!float;
    }

    /// ditto
    @property void opacity(float value)
    {
        setValue(opacityProperty, Value(value));
    }

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
    * The default is its own bounds, and unless something clips it that default
    * is a claim rather than a fact: a visual drawing a shadow, a focus ring or
    * an overshooting glyph draws outside it and must widen this to say so.
    *
    * What the framework promises is that every pixel inside the region a
    * visual declares here, or names through invalidateVisual(Rect), is
    * repainted after that visual is invalidated -- and that the place it
    * occupied before it moved is repainted to the accuracy of this.
    *
    * What it does not promise is that nothing else is repainted; the region is
    * a lower bound.  Nor does it promise anything at all about drawing outside
    * the region declared here: a visual that understated its reach pays for it
    * in pixels that stay on the screen after they should have gone.
    *
    * A clipping ancestor is the one thing that narrows the promise from the
    * other side, and narrowing it there is free: clippedToRootSpace cuts the
    * region down before it is asked for, because pixels that were never drawn
    * do not have to be drawn again.
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
    * **Two different things clip, and only one of them was asked for.**
    * clipToBounds is a visual saying it holds its own drawing in; the layout
    * clip is the room a parent granted an element that did not fit, and it
    * applies whether anybody asked or not -- see Element.arrange, which creates
    * the overflow on purpose by refusing to squeeze.  Where both are in force
    * what may be drawn is what both allow.
    *
    * Ink outside the bounds is otherwise still drawn, on purpose: a shadow or a
    * focus ring reaches past its element, and overflow that shows is overflow
    * that gets fixed.
    *
    * Five things are read on the way through, and each can end the walk or wrap
    * it: visible skips the subtree, a zero opacity skips it, the two clips
    * narrow it, a lower opacity puts it in a layer.  They are applied in that
    * order, so nothing is ever set up for a subtree that turns out not to be
    * drawn.
    *
    * Every push is undone on the way out whether onRender returns or throws, so
    * an exception leaving a visual finds the context as balanced as it left it.
    */
    final void renderSubtree(DrawingContext context)
    in {
        assert(context !is null);
    }
    do {
        // Before the push rather than after it, so that a collapsed visual
        // costs the walk one property read and nothing else -- and so that its
        // children are never reached, whatever their own answer would be.
        if (!visible)
            return;

        // Fully transparent is fully absent from the screen, so there is
        // nothing to draw and no layer worth opening to draw it into.  Written
        // as a refusal so that a NaN that got past the validator lands here
        // rather than opening a layer nobody can see out of.
        immutable alpha = opacity;

        if (!(alpha > 0))
            return;

        context.pushTransform(Matrix.translation(_arrangedRect.x, _arrangedRect.y));
        scope (exit) context.popTransform();

        // Read once and kept, so that the pop matches the push whatever a
        // handler somewhere below does to the property in between.  The clip
        // goes on after the transform, because both rectangles are named in
        // this visual's own space.
        //
        // Two clips that are one push: the bounds this visual asked to be held
        // in, and the room the layout granted it.  Where both apply what is
        // drawable is what both allow, which is their intersection.
        Rect region;
        immutable held = layoutClip(region);
        immutable bounds = clipToBounds;

        if (bounds)
        {
            immutable own = Rect(0, 0, _arrangedRect.width, _arrangedRect.height);
            region = held ? region.intersect(own) : own;
        }

        immutable clips = bounds || held;

        if (clips)
            context.pushClip(region);

        // Registered after the transform's, so it runs before it: the clip
        // comes off first, in the reverse of the order they went on.
        scope (exit)
            if (clips)
                context.popClip();

        // Inside the clip, because what the layer composites is what survived
        // it -- and because a layer the size of an unclipped subtree is a
        // bigger surface for the same picture.  Nothing is pushed at full
        // opacity: that is the case every visual in an ordinary tree is in.
        immutable fades = alpha < 1;

        if (fades)
            context.pushOpacity(alpha);

        scope (exit)
            if (fades)
                context.popOpacity();

        onRender(context);

        auto order = drawOrder();

        foreach (i; 0 .. visualChildCount)
            visualChild(order.length ? order[i] : i).renderSubtree(context);
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

   /**
    * The topmost visual of this subtree lying under the point, or null when
    * nothing here does.
    *
    * **The point is in this visual's PARENT's coordinate space**, not its own.
    * That is the same convention renderSubtree follows -- it begins by pushing
    * this visual's own placement -- and the same one toRootSpace follows, which
    * includes this visual's own origin rather than stopping one short of it.
    * The consequence worth stating because it is the natural wrong guess: what
    * a window is handed is a plain client-area point, with no adjustment.
    *
    * Children are searched last to first, because that is the order they were
    * drawn in and the last one drawn is the one on top.  A visual answers for
    * itself only when none of its children did.
    *
    * **The search descends into children even when this visual does not contain
    * the point**, unless it clips.  renderSubtree draws a child wherever its
    * placement puts it -- outside its parent included -- and a child that can be
    * seen has to be one that can be hit.  Missing the parent is therefore the
    * obvious thing to prune on and the wrong thing to prune on; clipToBounds is
    * what makes the pruning true rather than a guess, because it is the parent
    * saying that nothing outside it was drawn in the first place.
    */
    Visual hitTest(Point point)
    {
        // Three refusals for three different reasons, and the subtree goes with
        // each: one layer is not there at all, one is there and deaf, and one
        // has nothing on the screen to aim at.
        //
        // That last one is a choice, and WPF made the other: there, a fully
        // transparent element still catches the mouse.  What is invisible is
        // not clickable reads better than the rule it replaces, and anything
        // that really wants to draw nothing and still take input says so with
        // isHitTestVisible left alone and nothing drawn.
        if (!visible || !isHitTestVisible || !(opacity > 0))
            return null;

        immutable local = Point(point.x - _arrangedRect.x, point.y - _arrangedRect.y);

        // The pruning the paragraph above says is only correct with a clip.
        // Against the bounds and not containsPoint: a Shape answering for its
        // own round outline is saying which of its pixels are it, and the clip
        // is about which pixels exist at all.
        if (clipToBounds
            && !Rect(0, 0, _arrangedRect.width, _arrangedRect.height).contains(local))
            return null;

        // And the part the layout cut away is not there to be hit either --
        // the same rule from the other direction, and the reason a caption
        // hanging out of its button cannot be clicked where it does not show.
        Rect granted;
        if (layoutClip(granted) && !granted.contains(local))
            return null;

        auto order = drawOrder();

        foreach_reverse (i; 0 .. visualChildCount)
            if (auto hit = visualChild(order.length ? order[i] : i).hitTest(local))
                return hit;

        return containsPoint(local) ? this : null;
    }

   /**
    * Where a point of this visual's own space falls in the space of the top of
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
    Point toRootSpace(Point point)
    {
        immutable offset = originInRoot();
        return Point(point.x + offset.x, point.y + offset.y);
    }

   /**
    * ditto
    *
    * A plain change of coordinates, with no opinion about whether the region
    * can be seen there.  clippedToRootSpace is the one that has the opinion.
    */
    Rect toRootSpace(Rect region)
    {
        immutable offset = originInRoot();
        return Rect(region.x + offset.x, region.y + offset.y, region.width, region.height);
    }

   /**
    * Where a region of this visual's own space really lands in the root's:
    * toRootSpace, cut down by every clipping ancestor on the way up.
    *
    * The answer is empty when the region is drawn nowhere at all -- when some
    * ancestor clips it away entirely -- and `Rect.init` is what "nowhere" comes
    * back as, so `empty` recognises it without a second test.
    *
    * This is what the repaint queue asks, and the reason it exists as a second
    * method rather than as an improvement to the first: a coordinate mapping
    * that silently returned less than it was given would be a poor mapping.
    * Here the narrowing is the point -- a region nobody can see is a region
    * nobody has to redraw, and before there was clipping there was no such
    * region and nothing to narrow.
    *
    * A visual's own clip counts, not only its ancestors'.  renderSubtree pushes
    * the clip before onRender, so a visual that clips clips itself too.
    */
    Rect clippedToRootSpace(Rect region)
    {
        for (Visual v = this; v !is null; v = v.visualParent)
        {
            if (v.clipToBounds)
                region = region.intersect(
                    Rect(0, 0, v._arrangedRect.width, v._arrangedRect.height));

            Rect granted;
            if (v.layoutClip(granted))
                region = region.intersect(granted);

            if (region.empty)
                return Rect.init;

            // Up into the parent's space, which is the same step renderSubtree
            // takes downwards when it pushes this visual's placement.
            region.x += v._arrangedRect.x;
            region.y += v._arrangedRect.y;
        }

        return region;
    }

   /**
    * The other direction: where a point of the root's space falls in this
    * visual's own.
    *
    * What an event carrying a window-relative position is asked for when a
    * handler somewhere down the tree wants it in local terms.
    */
    Point fromRootSpace(Point point)
    {
        immutable offset = originInRoot();
        return Point(point.x - offset.x, point.y - offset.y);
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
    * Whether the point, in this visual's own coordinate space, is on it.
    *
    * The default is its own box: the origin to arrangedRect's width and height,
    * with the near edges inside and the far ones belonging to the neighbour.
    *
    * **Not renderBounds.** That one is a claim about ink -- a TextBlock widens
    * it to cover the accents and descenders that overshoot the box -- and ink
    * is not a surface to interact with.  Nobody should be able to click the
    * overshoot of a letter.  A Shape will override this with its geometry, so
    * that the inside of a circle is round rather than square.
    *
    * A visual that draws nothing still answers yes, which is what makes a panel
    * swallow the clicks that reach it.  That is WPF's base rule too, where the
    * exception is a Panel with no Background saying no on purpose -- and that
    * exception arrives here when brushes do.
    */
    bool containsPoint(Point point)
    {
        return Rect(0, 0, _arrangedRect.width, _arrangedRect.height).contains(point);
    }

   /**
    * The room the layout granted this visual, in its own space, and whether the
    * layout is holding it to that room at all.
    *
    * False from a plain Visual, and that is the honest answer rather than a
    * stub: a visual has a placement and nothing that granted it, so there is
    * nothing for it to be held inside of.  Element overrides this -- it is the
    * one that hands out slots and the one that refuses to squeeze anything into
    * a slot too small, which is what creates something to hold in the first
    * place.
    *
    * Read on every render and every hit test, so it answers rather than
    * allocates.
    */
    bool layoutClip(out Rect region)
    {
        return false;
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
   /*
    * The order to visit the children in, back to front, or an empty slice when
    * that is simply the order they are already in.
    *
    * The empty answer is the ordinary one and the reason for the scan: a tree
    * where nobody set a zIndex allocates nothing and compares nothing, which is
    * every tree until somebody wants a thing on top.  Both walks read it the
    * same way, and that is what keeps the drawing order and the hit order from
    * drifting apart -- they cannot, because there is one answer.
    *
    * The scan itself is one property read per child per walk.  Keeping a flag
    * on the parent instead would need a child's change to reach its parent, and
    * a stale flag is a wrong z-order that nothing catches; this is the cheap
    * thing that cannot go stale.
    */
    size_t[] drawOrder()
    {
        immutable count = visualChildCount;
        bool ordered;

        foreach (i; 0 .. count)
        {
            if (visualChild(i).zIndex != 0)
            {
                ordered = true;
                break;
            }
        }

        if (!ordered)
            return null;

        auto order = new size_t[count];

        foreach (i; 0 .. count)
            order[i] = i;

        import std.algorithm.mutation : SwapStrategy;
        import std.algorithm.sorting : sort;

        // Stable, so that equal children keep the order they were added in --
        // which is the order the rest of this file means by "the last one drawn
        // is the one on top".
        sort!((a, b) => visualChild(a).zIndex < visualChild(b).zIndex,
              SwapStrategy.stable)(order);

        return order;
    }

   /*
    * Where this visual's own origin sits in the root's space: the sum of every
    * placement from the root down to and including this one.
    */
    Point originInRoot()
    {
        float dx = 0;
        float dy = 0;

        for (Visual v = this; v !is null; v = v.visualParent)
        {
            dx += v._arrangedRect.x;
            dy += v._arrangedRect.y;
        }

        return Point(dx, dy);
    }

    // An element that has never been drawn is out of date by definition, so the
    // mark starts raised and only a drain lowers it.
    bool _visualDirty = true;
}

/*
 * Whether a number is a share of something: nothing to all of it, and no NaN.
 *
 * Written as a pair of comparisons rather than as `>= 0 && <= 1`, so that NaN
 * is refused by both of them instead of slipping through whichever one it makes
 * true -- the same shape Rect.empty uses, and for the same reason.
 */
private bool isFraction(const(Value) value)
{
    immutable share = value.get!float;
    return share >= 0 && share <= 1;
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

unittest
{
    // The point arrives in the parent's space, so a lone visual is hit at the
    // coordinates its own placement names -- not at its own origin.
    auto node = new Node("only", Rect(10, 20, 100, 50));

    assert(node.hitTest(Point(10, 20)) is node, "its near corner");
    assert(node.hitTest(Point(60, 40)) is node);
    assert(node.hitTest(Point(109, 69)) is node);

    assert(node.hitTest(Point(9, 40)) is null, "just outside");
    assert(node.hitTest(Point(110, 40)) is null, "and the far edge belongs to nobody here");
    assert(node.hitTest(Point(-1, -1)) is null);
}

unittest
{
    // A child is found before the parent it sits in, and the coordinates
    // compose down the chain.
    auto outer = new Node("outer", Rect(10, 10, 200, 100));
    auto inner = new Node("inner", Rect(20, 20, 50, 30));
    outer.add(inner);

    assert(outer.hitTest(Point(35, 35)) is inner, "inside both, so the deeper one");
    assert(outer.hitTest(Point(15, 15)) is outer, "inside the parent only");
    assert(outer.hitTest(Point(5, 5)) is null);

    // The inner one lives at (30, 30) in the root's space, which is the same
    // arithmetic read the other way round.
    assert(inner.toRootSpace(Point(0, 0)) == Point(30, 30));
    assert(inner.fromRootSpace(Point(35, 35)) == Point(5, 5));
}

unittest
{
    // Two overlapping siblings: the one added later is drawn last, so it is on
    // top, so it is what the mouse finds.
    auto root = new Node("root", Rect(0, 0, 200, 200));
    auto under = new Node("under", Rect(0, 0, 100, 100));
    auto over = new Node("over", Rect(50, 50, 100, 100));
    root.add(under);
    root.add(over);

    assert(root.hitTest(Point(75, 75)) is over, "where they overlap, the later one");
    assert(root.hitTest(Point(25, 25)) is under);
    assert(root.hitTest(Point(125, 125)) is over);
}

unittest
{
    // A child placed outside its parent is drawn there, so it is hit there.
    //
    // This is the test that fails the moment somebody prunes the walk on the
    // parent missing -- which is the obvious optimisation and is wrong until
    // there is clipping to make it right.
    auto parent = new Node("parent", Rect(0, 0, 50, 50));
    auto escapee = new Node("escapee", Rect(100, 100, 40, 40));
    parent.add(escapee);

    assert(parent.hitTest(Point(120, 120)) is escapee,
           "well outside the parent, and still exactly where it is drawn");
    assert(parent.hitTest(Point(25, 25)) is parent);
    assert(parent.hitTest(Point(80, 80)) is null, "in neither of them");
}

unittest
{
    // Two visuals laid end to end: the line they share belongs to one of them,
    // and which one does not depend on the order they are tested in.
    auto root = new Node("root", Rect(0, 0, 200, 100));
    auto left = new Node("left", Rect(0, 0, 50, 100));
    auto right = new Node("right", Rect(50, 0, 50, 100));
    root.add(left);
    root.add(right);

    assert(root.hitTest(Point(49, 50)) is left);
    assert(root.hitTest(Point(50, 50)) is right, "the shared edge is the far one's");
}

unittest
{
    // A visual with no size is not in the way of anything.
    auto root = new Node("root", Rect(0, 0, 100, 100));
    auto flat = new Node("flat", Rect(10, 10, 0, 40));
    root.add(flat);

    assert(root.hitTest(Point(10, 20)) is root);
}

unittest
{
    // A visual the mouse cannot find takes its whole subtree with it, so what
    // is behind becomes reachable -- which is what "clicks pass through this
    // layer" has to mean to be useful.
    auto root = new Node("root", Rect(0, 0, 200, 200));
    auto under = new Node("under", Rect(0, 0, 200, 200));
    auto glass = new Node("glass", Rect(0, 0, 200, 200));
    auto label = new Node("label", Rect(50, 50, 40, 20));
    root.add(under);
    root.add(glass);
    glass.add(label);

    assert(root.hitTest(Point(60, 60)) is label, "the topmost thing there");

    glass.isHitTestVisible = false;
    assert(root.hitTest(Point(60, 60)) is under,
           "the layer is gone and its label with it, so what is behind answers");

    // And it is only about the mouse: the layer is still drawn, and still asks
    // to be drawn again.
    renderLog = null;
    root.renderSubtree(new RecordingContext);
    assert(renderLog == ["root", "under", "glass", "label"]);

    glass.isHitTestVisible = true;
    assert(root.hitTest(Point(60, 60)) is label);
}

unittest
{
    // On by default, and an ordinary property in every other respect.
    auto node = new Node;

    assert(node.isHitTestVisible);
    assert(!node.hasLocalValue(Visual.isHitTestVisibleProperty));

    node.isHitTestVisible = false;
    assert(node.hasLocalValue(Visual.isHitTestVisibleProperty));

    node.clearValue(Visual.isHitTestVisibleProperty);
    assert(node.isHitTestVisible);
}

unittest
{
    // A visual that is not there is neither drawn nor found, and its children
    // go with it -- the layer is switched off, not the one node.
    auto root = new Node("root", Rect(0, 0, 200, 200));
    auto under = new Node("under", Rect(0, 0, 200, 200));
    auto panel = new Node("panel", Rect(0, 0, 200, 200));
    auto label = new Node("label", Rect(50, 50, 40, 20));
    root.add(under);
    root.add(panel);
    panel.add(label);

    assert(root.hitTest(Point(60, 60)) is label, "the topmost thing there");

    panel.visible = false;

    renderLog = null;
    root.renderSubtree(new RecordingContext);
    assert(renderLog == ["root", "under"], "the panel is gone and its label with it");

    assert(root.hitTest(Point(60, 60)) is under, "so what is behind answers");

    // The label never stopped being visible in its own right.  Nobody asked it.
    assert(label.visible);

    // Which is the difference from a deaf layer: that one is still drawn.
    panel.visible = true;
    panel.isHitTestVisible = false;

    renderLog = null;
    root.renderSubtree(new RecordingContext);
    assert(renderLog == ["root", "under", "panel", "label"]);
    assert(root.hitTest(Point(60, 60)) is under);
}

unittest
{
    // On by default, and an ordinary property in every other respect.
    auto node = new Node;

    assert(node.visible);
    assert(!node.hasLocalValue(Visual.visibleProperty));

    node.visible = false;
    assert(node.hasLocalValue(Visual.visibleProperty));

    node.clearValue(Visual.visibleProperty);
    assert(node.visible);
}

unittest
{
    // A clip goes on inside the visual's own space and comes off again, and it
    // is its bounds that are pushed rather than anything a child asked for.
    auto root = new Node("root", Rect(10, 20, 200, 100));
    auto inner = new Node("inner", Rect(5, 5, 60, 40));
    root.add(inner);

    inner.clipToBounds = true;

    auto context = new RecordingContext;
    root.renderSubtree(context);

    assert(context.clips == [Rect(15, 25, 60, 40)],
           "the child's own bounds, at the origin its placement gives it");
    assert(context.clipDepth == 0, "and the walk left the stack as it found it");
    assert(context.depth == 0);
}

unittest
{
    // Off by default, so a subtree that draws outside itself is still drawn --
    // and still hit -- exactly where it draws.
    auto parent = new Node("parent", Rect(0, 0, 50, 50));
    auto escapee = new Node("escapee", Rect(100, 100, 40, 40));
    parent.add(escapee);

    assert(parent.hitTest(Point(120, 120)) is escapee, "nobody clipped it");

    parent.clipToBounds = true;

    assert(parent.hitTest(Point(120, 120)) is null,
           "outside the parent is now outside everything under it");
    assert(parent.hitTest(Point(25, 25)) is parent, "and inside is unchanged");

    // The parent's own far edge belongs to the neighbour, on the same terms
    // Rect.contains has everywhere else.
    assert(parent.hitTest(Point(49, 49)) is parent);
    assert(parent.hitTest(Point(50, 50)) is null);

    auto context = new RecordingContext;
    renderLog = null;
    parent.renderSubtree(context);

    // Still walked and still drawn: what the clip removes is pixels, and the
    // recorder is not a rasteriser.  What it can show is that the clip was
    // pushed around the whole subtree.
    assert(renderLog == ["parent", "escapee"]);
    assert(context.clips == [Rect(0, 0, 50, 50)]);
}

unittest
{
    // Where a region really lands: the origins compose down the chain, and
    // every clip on the way cuts what is left of it.
    auto root = new Node("root", Rect(0, 0, 300, 300));
    auto frame = new Node("frame", Rect(10, 10, 100, 100));
    auto inner = new Node("inner", Rect(20, 20, 200, 200));
    root.add(frame);
    frame.add(inner);

    immutable whole = Rect(0, 0, 200, 200);

    // With nothing clipping the two answers agree, however far outside its
    // ancestors the region reaches.
    assert(inner.clippedToRootSpace(whole) == Rect(30, 30, 200, 200));
    assert(inner.clippedToRootSpace(whole) == inner.toRootSpace(whole));

    frame.clipToBounds = true;

    // The frame is 100 wide at (10, 10); inner starts 20 into it, so 80 of
    // inner's own 200 survive.
    assert(inner.clippedToRootSpace(whole) == Rect(30, 30, 80, 80));
    assert(inner.toRootSpace(whole) == Rect(30, 30, 200, 200), "and the mapping still says what it always said");

    // Entirely outside the clip is nowhere at all, and nowhere is Rect.init.
    assert(inner.clippedToRootSpace(Rect(100, 100, 50, 50)) == Rect.init);
    assert(inner.clippedToRootSpace(Rect(100, 100, 50, 50)).empty);

    // A visual's own clip counts too, because it clips its own drawing as well
    // as its children's.
    frame.clipToBounds = false;
    inner.clipToBounds = true;

    assert(inner.clippedToRootSpace(Rect(0, 0, 300, 300)) == Rect(30, 30, 200, 200),
           "cut to its own bounds before it was moved anywhere");
}

unittest
{
    // Off by default, and an ordinary property in every other respect.
    auto node = new Node;

    assert(!node.clipToBounds, "overflow is seen until somebody says otherwise");
    assert(!node.hasLocalValue(Visual.clipToBoundsProperty));

    node.clipToBounds = true;
    assert(node.hasLocalValue(Visual.clipToBoundsProperty));

    node.clearValue(Visual.clipToBoundsProperty);
    assert(!node.clipToBounds);
}

unittest
{
    // zIndex reorders the drawing, and the mouse follows it backwards: the two
    // walks read one answer, so they cannot disagree.
    auto root = new Node("root", Rect(0, 0, 200, 200));
    auto first = new Node("first", Rect(0, 0, 100, 100));
    auto second = new Node("second", Rect(0, 0, 100, 100));
    root.add(first);
    root.add(second);

    renderLog = null;
    root.renderSubtree(new RecordingContext);
    assert(renderLog == ["root", "first", "second"], "tree order until told otherwise");
    assert(root.hitTest(Point(50, 50)) is second, "and the last one drawn is on top");

    first.zIndex = 1;

    renderLog = null;
    root.renderSubtree(new RecordingContext);
    assert(renderLog == ["root", "second", "first"], "raised above the one after it");
    assert(root.hitTest(Point(50, 50)) is first, "and the mouse turned round with it");

    // Negative works from the other end, and clearing puts it back.
    first.clearValue(Visual.zIndexProperty);
    second.zIndex = -1;

    renderLog = null;
    root.renderSubtree(new RecordingContext);
    assert(renderLog == ["root", "second", "first"]);
    assert(root.hitTest(Point(50, 50)) is first);
}

unittest
{
    // Equal children keep the order they were added in, which is what makes the
    // sort worth insisting is stable: three at one level and one raised over
    // them must leave the three where they were.
    auto root = new Node("root", Rect(0, 0, 200, 200));
    auto a = new Node("a", Rect(0, 0, 100, 100));
    auto b = new Node("b", Rect(0, 0, 100, 100));
    auto c = new Node("c", Rect(0, 0, 100, 100));
    auto top = new Node("top", Rect(0, 0, 100, 100));
    root.add(a);
    root.add(b);
    root.add(c);
    root.add(top);

    top.zIndex = 5;
    b.zIndex = 5;

    renderLog = null;
    root.renderSubtree(new RecordingContext);
    assert(renderLog == ["root", "a", "c", "b", "top"],
           "a and c keep their order, and so do b and top");
}

unittest
{
    // A child never leaves its parent's layer, however high it is raised.
    auto root = new Node("root", Rect(0, 0, 200, 200));
    auto left = new Node("left", Rect(0, 0, 200, 200));
    auto right = new Node("right", Rect(0, 0, 200, 200));
    auto raised = new Node("raised", Rect(0, 0, 200, 200));
    root.add(left);
    root.add(right);
    left.add(raised);

    raised.zIndex = 1000;

    renderLog = null;
    root.renderSubtree(new RecordingContext);
    assert(renderLog == ["root", "left", "raised", "right"], "still under its uncle");
    assert(root.hitTest(Point(50, 50)) is right);
}

unittest
{
    // Zero by default, and an ordinary property in every other respect.
    auto node = new Node;

    assert(node.zIndex == 0);
    assert(!node.hasLocalValue(Visual.zIndexProperty));

    node.zIndex = -3;
    assert(node.zIndex == -3);
    assert(node.hasLocalValue(Visual.zIndexProperty));

    node.clearValue(Visual.zIndexProperty);
    assert(node.zIndex == 0);
}

unittest
{
    // Full opacity costs nothing: no layer is opened for the case every
    // ordinary visual is in.
    auto root = new Node("root", Rect(0, 0, 100, 100));
    auto child = new Node("child", Rect(0, 0, 50, 50));
    root.add(child);

    auto context = new RecordingContext;
    renderLog = null;
    root.renderSubtree(context);

    assert(renderLog == ["root", "child"]);
    assert(context.opacities.length == 0, "nobody faded anything");

    // Below one, a layer -- one, around the visual and everything under it.
    child.opacity = 0.25f;

    context = new RecordingContext;
    renderLog = null;
    root.renderSubtree(context);

    assert(renderLog == ["root", "child"], "a faded visual is still drawn");
    assert(context.opacities == [0.25f]);
    assert(context.opacityDepth == 0, "and the layer came off again");
}

unittest
{
    // Nested layers, one per visual: the compositing multiplies because each
    // one composites what the one inside it produced.
    auto root = new Node("root", Rect(0, 0, 100, 100));
    auto middle = new Node("middle", Rect(0, 0, 100, 100));
    auto inner = new Node("inner", Rect(0, 0, 100, 100));
    root.add(middle);
    middle.add(inner);

    middle.opacity = 0.5f;
    inner.opacity = 0.5f;

    auto context = new RecordingContext;
    root.renderSubtree(context);

    assert(context.opacities == [0.5f, 0.5f], "as asked for, not multiplied here");
    assert(context.opacityDepth == 0);
}

unittest
{
    // Zero is WPF's Hidden: nothing drawn, nothing clickable, and the room it
    // takes is nobody else's.
    auto root = new Node("root", Rect(0, 0, 200, 200));
    auto under = new Node("under", Rect(0, 0, 200, 200));
    auto ghost = new Node("ghost", Rect(0, 0, 200, 200));
    auto label = new Node("label", Rect(50, 50, 40, 20));
    root.add(under);
    root.add(ghost);
    ghost.add(label);

    assert(root.hitTest(Point(60, 60)) is label);

    ghost.opacity = 0;

    auto context = new RecordingContext;
    renderLog = null;
    root.renderSubtree(context);

    assert(renderLog == ["root", "under"], "nothing to draw, so nothing was drawn");
    assert(context.opacities.length == 0, "and no layer opened to draw it into");
    assert(root.hitTest(Point(60, 60)) is under, "and nothing to click either");

    // Which is the difference from collapsing it: the placement is untouched.
    assert(ghost.arrangedRect == Rect(0, 0, 200, 200));
}

unittest
{
    // A visual that throws out of the middle of a frame leaves the context as
    // it found it.  This is the test that fails the day somebody replaces a
    // scope (exit) with a line after the call.
    import std.exception : assertThrown;

    static class Thrower : Node
    {
        this()
        {
            super("thrower", Rect(0, 0, 50, 50));
        }

        protected override void onRender(DrawingContext context)
        {
            throw new Exception("out of the middle of a frame");
        }
    }

    auto root = new Node("root", Rect(0, 0, 200, 200));
    auto thrower = new Thrower;
    root.add(thrower);

    thrower.clipToBounds = true;
    thrower.opacity = 0.5f;

    auto context = new RecordingContext;
    assertThrown(root.renderSubtree(context));

    assert(context.clipDepth == 0, "the clip came off");
    assert(context.opacityDepth == 0, "and the layer");
    assert(context.depth == 0, "and the transform under both of them");
}

unittest
{
    // A share of something, and nothing else.
    import std.exception : assertThrown;

    auto node = new Node;

    assert(node.opacity == 1, "opaque until somebody fades it");
    assert(!node.hasLocalValue(Visual.opacityProperty));

    node.opacity = 0.5f;
    assert(node.opacity == 0.5f);

    assertThrown(node.setValue(Visual.opacityProperty, Value(2.0f)));
    assertThrown(node.setValue(Visual.opacityProperty, Value(-0.5f)));
    assertThrown(node.setValue(Visual.opacityProperty, Value(float.nan)));
    assert(node.opacity == 0.5f, "and every refused write left it alone");

    node.clearValue(Visual.opacityProperty);
    assert(node.opacity == 1);
}
