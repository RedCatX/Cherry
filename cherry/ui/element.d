module cherry.ui.element;

import cherry.core.multicast : event;
import cherry.core.obj;
import cherry.core.property;
import cherry.core.rtti;
import cherry.core.value;
import cherry.platform.render : DrawingContext, Matrix, Rect, Size, Thickness;
import cherry.ui.event;
import cherry.ui.layout : LayoutManager;
import cherry.ui.styledelement;
import cherry.ui.visual;

/**
 * Where an element sits in the horizontal room its parent gave it.
 *
 * Stretch is the odd one out: the other three place the element at the size it
 * asked for and leave the rest of the room empty, while stretch makes it take
 * the room instead.  An element that cannot stretch -- one with a width of its
 * own, or a maximum, or content needing more room than there is -- falls back
 * to the middle, or to the left edge when it overflows, so that what gets cut
 * off is the far side rather than both.
 *
 * The member order is WPF's, which means the enum's own `.init` is `left`
 * while the property defaults to `stretch`.  They differ on purpose: an
 * alignment nobody chose should fill the space, but a bare `HorizontalAlignment`
 * variable has to start somewhere and the familiar numbering is worth more
 * than the coincidence.
 */
enum HorizontalAlignment
{
    left,
    center,
    right,
    stretch
}

/// ditto, vertically.
enum VerticalAlignment
{
    top,
    center,
    bottom,
    stretch
}

/**
 * Base class for every node of the element tree.
 *
 * The tree models visual containment -- the analogue of Delphi's
 * TControl.Parent, not TComponent.Owner.  Routed events, property value
 * inheritance, style lookup, layout and rendering all traverse this tree.
 * Non-visual property-bearing objects (fonts, brushes, styles) remain plain
 * CherryObjects and never enter it.
 *
 * Invariants maintained by the mutation methods:
 *   - a child's parent is always the element whose child list contains it;
 *   - an element can have at most one parent (detach before re-adding);
 *   - the tree is acyclic (an ancestor cannot become a child).
 */
class Element : Visual
{
    shared static this()
    {
        // Unset by default.  A size an element was never given is not zero and
        // not any other number: it is a question the layout answers, and only
        // an element that was told otherwise overrides the answer.
        PropertyMetadata sizeMeta;
        sizeMeta.defaultValue = Value.init;
        sizeMeta.affectsMeasure = true;

        widthProperty  = Property.register("Width",  getRtti!float(), getRtti!Element(), sizeMeta);
        heightProperty = Property.register("Height", getRtti!float(), getRtti!Element(), sizeMeta);

        // The arranged size, written by arrange() and by nothing else: the key
        // stays private, so the only way into these is through the layout pass
        // that produced them.
        PropertyMetadata actualMeta;
        actualMeta.defaultValue = Value(0.0f);

        actualWidthKey  = Property.registerReadOnly("ActualWidth",  getRtti!float(), getRtti!Element(), actualMeta);
        actualHeightKey = Property.registerReadOnly("ActualHeight", getRtti!float(), getRtti!Element(), actualMeta);

        // Written by the input code as the pointer moves and by nothing else,
        // so it takes a key too.
        //
        // No affectsRender, deliberately.  Most elements on the chain look
        // exactly the same hovered as not -- every container between the
        // pointer and the window is on it -- and a flag here would ask each of
        // them for a repaint on every crossing.  A control that does change
        // appearance says so itself from its handler, and when there are styles
        // a trigger will say it instead.
        PropertyMetadata mouseOverMeta;
        mouseOverMeta.defaultValue = Value(false);

        isMouseOverKey = Property.registerReadOnly("IsMouseOver", getRtti!bool(), getRtti!Element(), mouseOverMeta);

        // Space the element keeps clear around itself, and therefore part of
        // what it costs its parent: a margin changes the answer measure gives,
        // not merely where arrange puts things.
        PropertyMetadata marginMeta;
        marginMeta.defaultValue = Value(Thickness.init);
        marginMeta.affectsMeasure = true;

        marginProperty = Property.register("Margin", getRtti!Thickness(), getRtti!Element(), marginMeta);

        // Bounds on the size, as plain numbers rather than as the set-or-unset
        // that Width and Height need.  Absence has a number here: 0 is what
        // max() ignores and infinity is what min() ignores, so a bound nobody
        // gave takes part in the arithmetic and changes nothing.  That is what
        // NaN could not do, which is the whole reason Width is different.
        //
        // The infinity stops here.  Only Width and Height reach the platform,
        // and only they are cast to int on the way; nothing writes a bound
        // into either, and nothing should start.
        PropertyMetadata minMeta;
        minMeta.defaultValue = Value(0.0f);
        minMeta.affectsMeasure = true;

        PropertyMetadata maxMeta;
        maxMeta.defaultValue = Value(float.infinity);
        maxMeta.affectsMeasure = true;

        minWidthProperty  = Property.register("MinWidth",  getRtti!float(), getRtti!Element(), minMeta);
        minHeightProperty = Property.register("MinHeight", getRtti!float(), getRtti!Element(), minMeta);
        maxWidthProperty  = Property.register("MaxWidth",  getRtti!float(), getRtti!Element(), maxMeta);
        maxHeightProperty = Property.register("MaxHeight", getRtti!float(), getRtti!Element(), maxMeta);

        // Alignment moves an element inside room it has already been granted
        // and never changes how much it asks for, so it is the cheaper of the
        // two invalidations.
        PropertyMetadata horizontalMeta;
        horizontalMeta.defaultValue = Value(HorizontalAlignment.stretch);
        horizontalMeta.affectsArrange = true;

        PropertyMetadata verticalMeta;
        verticalMeta.defaultValue = Value(VerticalAlignment.stretch);
        verticalMeta.affectsArrange = true;

        horizontalAlignmentProperty = Property.register("HorizontalAlignment",
            getRtti!HorizontalAlignment(), getRtti!Element(), horizontalMeta);
        verticalAlignmentProperty = Property.register("VerticalAlignment",
            getRtti!VerticalAlignment(), getRtti!Element(), verticalMeta);

        sizeChangedEvent = RoutedEvent.register("SizeChanged", RoutingStrategy.direct, getRtti!Element());
    }

    static immutable(Property) widthProperty;
    static immutable(Property) heightProperty;
    static immutable(Property) marginProperty;
    static immutable(Property) minWidthProperty;
    static immutable(Property) minHeightProperty;
    static immutable(Property) maxWidthProperty;
    static immutable(Property) maxHeightProperty;
    static immutable(Property) horizontalAlignmentProperty;
    static immutable(Property) verticalAlignmentProperty;
    static immutable(RoutedEvent) sizeChangedEvent;

   /**
    * The size arrange settled on, as read-only properties.  They are what the
    * element is; width and height are only what it asked to be.
    */
    static @property immutable(Property) actualWidthProperty() pure nothrow
    {
        return actualWidthKey.property;
    }

    /// ditto
    static @property immutable(Property) actualHeightProperty() pure nothrow
    {
        return actualHeightKey.property;
    }

   /**
    * Whether the pointer is over this element or over anything inside it.
    *
    * True for every element between the one under the pointer and the root, so
    * a container knows the mouse is somewhere in it without watching each of
    * its children.  That is what makes it the thing a control's appearance
    * hangs off: a button stays lit while the pointer is over its label.
    *
    * Read-only, and the key never leaves this class: the pointer's position is
    * something the framework knows and user code reports on, never the other
    * way round.
    */
    static @property immutable(Property) isMouseOverProperty() pure nothrow
    {
        return isMouseOverKey.property;
    }

    /// ditto
    @property bool isMouseOver() const
    {
        return getValue(isMouseOverProperty).get!bool;
    }

   /**
    * The width this element asks for, or NaN when it asks for none.
    *
    * Unset is the ordinary state and the useful one: it means "size me to my
    * content" and leaves the decision with the layout.  Assigning a width
    * takes the decision away -- the element then insists on exactly this much,
    * whatever its content would have needed.  clearValue(widthProperty) hands
    * it back.
    *
    * Absence is stored as an empty Value rather than as NaN, so a width that
    * was never set cannot slip into arithmetic and quietly poison a whole
    * subtree of sums.  NaN appears only here, at the boundary where a float
    * has to be returned; layout asks isWidthSet and never reads this.
    */
    @property float width() const
    {
        auto value = getValue(widthProperty);
        return value.empty ? float.nan : value.get!float;
    }

    /// ditto
    @property void width(float value)
    {
        setValue(widthProperty, Value(value));
    }

    /// ditto
    @property float height() const
    {
        auto value = getValue(heightProperty);
        return value.empty ? float.nan : value.get!float;
    }

    /// ditto
    @property void height(float value)
    {
        setValue(heightProperty, Value(value));
    }

   /**
    * The space this element keeps clear around itself.
    *
    * It is part of what the element costs: measure takes it out of the room on
    * offer and puts it back onto the answer, so a parent adding its children
    * up is adding up the space they occupy and the space they insist on
    * keeping empty.
    */
    @property Thickness margin() const
    {
        return getValue(marginProperty).get!Thickness;
    }

    /// ditto
    @property void margin(Thickness value)
    {
        setValue(marginProperty, Value(value));
    }

   /**
    * Bounds on how small and how large the element may end up.
    *
    * Unlike width these are plain numbers with no unset state, because
    * absence already has one: a minimum of zero and a maximum of infinity take
    * part in the arithmetic and change nothing.  Width has to distinguish
    * "none given" from a number because NaN would spread through sums; a bound
    * is never summed, only ever compared, so it does not.
    *
    * A minimum outranks a maximum when the two contradict each other, rather
    * than leaving a range nothing can satisfy.
    */
    @property float minWidth() const
    {
        return getValue(minWidthProperty).get!float;
    }

    /// ditto
    @property void minWidth(float value)
    {
        setValue(minWidthProperty, Value(value));
    }

    /// ditto
    @property float minHeight() const
    {
        return getValue(minHeightProperty).get!float;
    }

    /// ditto
    @property void minHeight(float value)
    {
        setValue(minHeightProperty, Value(value));
    }

    /// ditto
    @property float maxWidth() const
    {
        return getValue(maxWidthProperty).get!float;
    }

    /// ditto
    @property void maxWidth(float value)
    {
        setValue(maxWidthProperty, Value(value));
    }

    /// ditto
    @property float maxHeight() const
    {
        return getValue(maxHeightProperty).get!float;
    }

    /// ditto
    @property void maxHeight(float value)
    {
        setValue(maxHeightProperty, Value(value));
    }

   /**
    * Where the element sits in the room its parent gave it.
    *
    * Stretch, the default, means the element takes the room; anything else
    * means it takes the size it asked for and sits somewhere in what it was
    * offered.
    */
    @property HorizontalAlignment horizontalAlignment() const
    {
        return getValue(horizontalAlignmentProperty).get!HorizontalAlignment;
    }

    /// ditto
    @property void horizontalAlignment(HorizontalAlignment value)
    {
        setValue(horizontalAlignmentProperty, Value(value));
    }

    /// ditto
    @property VerticalAlignment verticalAlignment() const
    {
        return getValue(verticalAlignmentProperty).get!VerticalAlignment;
    }

    /// ditto
    @property void verticalAlignment(VerticalAlignment value)
    {
        setValue(verticalAlignmentProperty, Value(value));
    }

   /**
    * Whether a width of its own was set on this element.  The question layout
    * asks, and the honest form of "is width NaN".
    */
    @property bool isWidthSet() const
    {
        return !getValue(widthProperty).empty;
    }

    /// ditto
    @property bool isHeightSet() const
    {
        return !getValue(heightProperty).empty;
    }

   /**
    * The size this element was last arranged at.
    */
    @property float actualWidth() const
    {
        return getValue(actualWidthProperty).get!float;
    }

    /// ditto
    @property float actualHeight() const
    {
        return getValue(actualHeightProperty).get!float;
    }

   /**
    * Raised after arrange has given this element a size different from the one
    * it had.  A direct routed event: a parent resizing does not mean a child
    * did, so there is nothing to bubble.
    */
    @event @property auto onSizeChanged()
    {
        return routedAccessor(this, sizeChangedEvent);
    }

   /**
    * The element this one is parented to, or null for a tree root.
    */
    @property inout(Element) parent() inout pure nothrow @nogc
    {
        return _parent;
    }

   /**
    * The logical parent, which today is the tree parent.
    *
    * The element tree is the only tree there is, so it answers for the logical
    * one as well.  The two part company when control templates arrive: a
    * button's border and its text will be visual children of the button and
    * logical children of nobody, and on that day the storage moves to
    * StyledElement and this override goes away.  Nothing at a call site
    * changes when it does, which is the reason the seam exists now.
    */
    override @property inout(Element) logicalParent() inout
    {
        return _parent;
    }

   /**
    * The topmost ancestor; the element itself when it has no parent.
    */
    @property Element root() pure nothrow @nogc
    {
        Element e = this;
        while (e._parent !is null)
            e = e._parent;
        return e;
    }

   /**
    * Number of direct children.
    */
    @property size_t childCount() const pure nothrow @nogc
    {
        return _children.length;
    }

   /**
    * Read-only, indexable forward range over the direct children.
    * The view is a snapshot of the current child list; structural changes
    * made after obtaining it are not reflected in the view.
    */
    @property ChildrenView children() pure nothrow @nogc
    {
        return ChildrenView(_children);
    }

   /**
    * Appends a child to the end of the child list.
    */
    void addChild(Element child)
    {
        insertChild(_children.length, child);
    }

   /**
    * Inserts a child at the given position in the child list.
    *
    * Throws: Exception when child is null, already parented, would create a
    * cycle, or index is out of range.
    */
    void insertChild(size_t index, Element child)
    {
        if (child is null)
            throw new Exception("Cannot add a null child.");
        if (child._parent is this)
            throw new Exception("The element is already a child of this element.");
        if (child._parent !is null)
            throw new Exception("The element already has a parent; detach it from its current parent first.");
        if (child is this || child.isAncestorOf(this))
            throw new Exception("Adding this element would create a cycle in the tree.");
        if (index > _children.length)
            throw new Exception("Child index is out of range.");

        _children = _children[0 .. index] ~ child ~ _children[index .. $];
        child._parent = this;

        // Here rather than in onAttached: a subclass may override that hook and
        // has no obligation to chain, and one that forgot would break layout
        // for its whole subtree with nothing at the call site to show for it.
        // What a tree does when it changes shape belongs to the tree.
        invalidateMeasure();
        child.invalidateMeasure();

        // It has never been drawn in this tree, whatever it did in the last
        // one.  Arranging will usually ask on its own, but only when the
        // placement changes -- a child re-added at the very rectangle it had
        // before would otherwise arrive invisible.
        child.invalidateVisual();

        child.onAttached(this);
    }

   /**
    * Removes a direct child.  The child keeps its own subtree.
    *
    * Throws: Exception when the element is not a direct child of this one.
    */
    void removeChild(Element child)
    {
        if (child is null || child._parent !is this)
            throw new Exception("The element is not a child of this element.");

        foreach (i, c; _children)
        {
            if (c is child)
            {
                _children = _children[0 .. i] ~ _children[i + 1 .. $];
                break;
            }
        }

        immutable vacated = child.arrangedRect;

        child._parent = null;

        invalidateMeasure();
        child.markLayoutDirty();

        // The hole a departing child leaves is the parent's to fill: the
        // child cannot ask for it, having just lost the tree the region was
        // expressed in.  arrangedRect is already in this element's space,
        // which is exactly what the region form wants.
        invalidateVisual(vacated);

        child.onDetached(this);
    }

   /**
    * Detaches every direct child.  Each child keeps its own subtree.
    */
    void clearChildren()
    {
        auto detached = _children;
        _children = null;

        if (detached.length)
            invalidateMeasure();

        foreach (child; detached)
        {
            // Same reasoning as removeChild: the hole is this element's to
            // fill, and arrangedRect is already in its coordinate space.
            invalidateVisual(child.arrangedRect);

            child._parent = null;
            child.markLayoutDirty();
            child.onDetached(this);
        }
    }

   /**
    * Removes this element from its parent.  Does nothing for a tree root.
    */
    void detach()
    {
        if (_parent !is null)
            _parent.removeChild(this);
    }

   /**
    * Registers a handler for a routed event on this element.
    *
    * Params:
    *     event = The routed event to listen for
    *     handler = Callback invoked when the event's route passes this element
    *     handledEventsToo = Invoke the handler even for events already
    *                        marked as handled
    */
    void addEventHandler(immutable(RoutedEvent) event, RoutedEventHandler handler, bool handledEventsToo = false)
    in {
        assert(event !is null);
        assert(handler !is null);
    }
    do {
        _handlers[event.id] ~= HandlerEntry(handler, handledEventsToo);
    }

   /**
    * Removes one registration of the handler for the event.  Does nothing
    * when the handler is not registered.
    */
    void removeEventHandler(immutable(RoutedEvent) event, RoutedEventHandler handler)
    in {
        assert(event !is null);
    }
    do {
        auto list = event.id in _handlers;
        if (list is null)
            return;

        foreach (i, entry; *list)
        {
            if (entry.handler == handler)
            {
                *list = (*list)[0 .. i] ~ (*list)[i + 1 .. $];
                return;
            }
        }
    }

   /**
    * Raises a routed event from this element.
    *
    * The route is captured before any handler runs, so tree mutations made
    * by handlers do not affect it: direct invokes this element's handlers
    * only, bubble walks from here up to the root, tunnel walks from the
    * root down to here.
    */
    void raiseEvent(RoutedEventArgs args)
    in {
        assert(args !is null);
    }
    do {
        args.initializeRoute(this);

        Element[] route = [this];
        foreach (ancestor; ancestors)
            route ~= ancestor;

        final switch (args.routedEvent.routingStrategy)
        {
            case RoutingStrategy.direct:
                invokeLocalHandlers(args);
                break;

            case RoutingStrategy.bubble:
                foreach (element; route)
                    element.invokeLocalHandlers(args);
                break;

            case RoutingStrategy.tunnel:
                foreach_reverse (element; route)
                    element.invokeLocalHandlers(args);
                break;
        }
    }

   /**
    * Whether this element is a (transitive) ancestor of the given one.
    * An element is not considered its own ancestor.
    */
    final bool isAncestorOf(scope const(Element) descendant) const pure nothrow @nogc
    {
        // Recursion instead of a loop: a const class reference cannot be
        // rebound, so walking the chain iteratively would need Rebindable.
        if (descendant is null || descendant._parent is null)
            return false;
        if (descendant._parent is this)
            return true;
        return isAncestorOf(descendant._parent);
    }

   /**
    * Whether this element is a (transitive) descendant of the given one.
    */
    final bool isDescendantOf(scope const(Element) ancestor) const pure nothrow @nogc
    {
        return ancestor !is null && ancestor.isAncestorOf(this);
    }

   /**
    * Forward range walking the parent chain from the immediate parent to the
    * tree root.  Used by property value inheritance and event routing.
    */
    auto ancestors() pure nothrow @nogc
    {
        return AncestorRange(_parent);
    }

   /**
    * Input range over the whole subtree below this element in depth-first
    * pre-order (children visited left to right).  Excludes the element
    * itself.  The tree must not be mutated while iterating.
    */
    auto descendants() pure nothrow
    {
        DescendantRange r;
        foreach_reverse (child; _children)
            r._stack ~= child;
        return r;
    }

   /**
    * Measures the element against the space the parent can offer, leaving the
    * answer in desiredSize.
    *
    * The margin comes out of what is offered and goes back onto the answer:
    * the parent pays for it either way, so it belongs in the price.  Width,
    * Height and the bounds fold into one range per axis, and it is that range
    * rather than the raw offer that the content is measured against -- an
    * element told to be 200 wide is measured against 200, so its content
    * arranges itself for the width it will really get.
    *
    * availableSize may be infinite on an axis, and a parent that wants to know
    * what a child would like unprompted is expected to say so that way rather
    * than by naming a large number.  Nothing infinite comes back out.  arrange
    * is the opposite: a rectangle is a place, and a place is never infinite.
    *
    * What comes back is also never larger than what was offered, so a parent
    * adding its children up is adding up sizes that fit in the room it has.
    * What the element really wanted is not lost -- unclippedDesiredSize keeps
    * it, and arrange goes back to it.
    */
    final void measure(Size availableSize)
    {
        // Clean, and asked the same question as last time: the answer cannot
        // have changed, so the subtree below is not asked again either.  This
        // is what makes a layout pass cost the dirty part of the tree rather
        // than the whole of it.
        if (!_measureDirty && availableSize == _previousConstraint)
            return;

        // The question is recorded before it is answered, so that a measure
        // reached again from inside measureOverride sees the one in flight.
        _previousConstraint = availableSize;

        immutable m = margin;

        // A margin wider than the room on offer would leave a negative amount,
        // which is not a size anything can be measured against.
        auto constraint = Size(notBelowZero(availableSize.width  - m.horizontal),
                               notBelowZero(availableSize.height - m.vertical));

        immutable limits = MinMax(this);

        constraint.width  = atLeast(atMost(constraint.width,  limits.maxWidth),  limits.minWidth);
        constraint.height = atLeast(atMost(constraint.height, limits.maxHeight), limits.minHeight);

        immutable measured = measureOverride(constraint);

        assert(measured.width < float.infinity && measured.height < float.infinity,
               "measureOverride must answer with a finite size even when it was "
               ~ "offered an infinite one: infinity is the question, never the answer.");

        // What the content really needs, before anything above has a say.  The
        // margin is excluded, so this lines up directly with the slot-less-
        // margin that arrange works in.
        _unclippedDesiredSize = Size(atLeast(measured.width,  limits.minWidth),
                                     atLeast(measured.height, limits.minHeight));

        // The margin goes back on before the answer leaves.  Kept as bare
        // floats between the two clamps, because a negative margin can drive
        // either below zero in between and flooring too early would hide its
        // effect on the cap against what was offered.
        auto totalWidth  = atMost(_unclippedDesiredSize.width,  limits.maxWidth)  + m.horizontal;
        auto totalHeight = atMost(_unclippedDesiredSize.height, limits.maxHeight) + m.vertical;

        totalWidth  = atMost(totalWidth,  availableSize.width);
        totalHeight = atMost(totalHeight, availableSize.height);

        _desiredSize = Size(notBelowZero(totalWidth), notBelowZero(totalHeight));
        _measureDirty = false;
    }

   /**
    * Places the element in the rectangle the parent settled on and records the
    * outcome in actualWidth, actualHeight and arrangedRect.
    *
    * The rectangle handed in is the slot, not the answer.  The margin comes
    * out of it, the alignment decides where in what is left the element sits,
    * and arrangedRect is where it ended up.  The slot is kept privately,
    * because it and not the placement is what a second arrange has to be
    * given.
    *
    * finalRect is always a real rectangle.  Unlike measure, arrange is never
    * handed infinity: a place to be is not a question.
    *
    * Raises onSizeChanged when the outcome differs from the last one, after
    * the children have been arranged -- so a handler looks at a subtree that
    * has already taken its new shape, not one halfway there.
    */
    final void arrange(Rect finalRect)
    in {
        assert(finalRect.width < float.infinity && finalRect.height < float.infinity,
               "arrange is given a place, and a place is never infinite.  A parent "
               ~ "that wants to know how big a child would like asks measure instead.");
    }
    do {
        // Clean, and into the same rectangle: nothing to do, children included.
        //
        // Both halves are needed.  "Clean" alone would skip an element being
        // moved somewhere new, which is most of what arranging is; the same
        // rectangle alone would skip one whose content changed underneath it.
        //
        // What makes this safe is that invalidateMeasure sets _arrangeDirty as
        // well and measure() never clears it, so _measureDirty implies
        // _arrangeDirty always holds: an element whose measure went stale
        // cannot slip out of arrange at the rectangle it already had.
        if (!_arrangeDirty && finalRect == _arrangeSlot)
            return;

        immutable previous = Size(actualWidth, actualHeight);

        _arrangeSlot = finalRect;

        immutable m = margin;
        immutable client = Size(notBelowZero(finalRect.width  - m.horizontal),
                                notBelowZero(finalRect.height - m.vertical));

        Size arrangeSize = client;

        // A slot too small is not made to fit by squeezing.  The element takes
        // the room it said it needed and overflows, which is visible and can be
        // clipped later; a squeezed element is wrong and says nothing about it.
        arrangeSize.width  = atLeast(arrangeSize.width,  _unclippedDesiredSize.width);
        arrangeSize.height = atLeast(arrangeSize.height, _unclippedDesiredSize.height);

        // Stretch is the only alignment that means "take the room".  Every
        // other one means "take the size you asked for and sit somewhere in
        // it" -- and the size it asked for is the unclipped one, because the
        // clipped one is what the parent could spare rather than what was
        // wanted.
        if (horizontalAlignment != HorizontalAlignment.stretch)
            arrangeSize.width = _unclippedDesiredSize.width;
        if (verticalAlignment != VerticalAlignment.stretch)
            arrangeSize.height = _unclippedDesiredSize.height;

        immutable limits = MinMax(this);

        // A maximum caps stretching; it does not cut the element below what its
        // content needs.  A MaxWidth smaller than the content is a limit on how
        // far the element may be pulled, not a promise to hide part of it.
        arrangeSize.width  = atMost(arrangeSize.width,
                                    atLeast(limits.maxWidth,  _unclippedDesiredSize.width));
        arrangeSize.height = atMost(arrangeSize.height,
                                    atLeast(limits.maxHeight, _unclippedDesiredSize.height));

        immutable arranged = arrangeOverride(arrangeSize);

        immutable vacated = _arrangedRect;

        _arrangedRect = Rect(
            finalRect.x + m.left + horizontalOffset(horizontalAlignment, client.width,  arranged.width),
            finalRect.y + m.top  + verticalOffset(verticalAlignment,     client.height, arranged.height),
            arranged.width,
            arranged.height);

        setValue(actualWidthKey,  Value(arranged.width));
        setValue(actualHeightKey, Value(arranged.height));

        // Cleared before the event, so that a handler calling invalidateArrange
        // is left invalid rather than having its request wiped out on the way
        // out of the call it made it from.
        _arrangeDirty = false;

        // An element that ended up somewhere new has to be drawn there, and
        // the place it left has to be drawn without it -- otherwise it stays
        // on the screen twice.  Guarded on the rectangle actually changing:
        // a pass that put it back where it was has nothing to repaint, and
        // asking anyway would keep the queue busy every frame.
        //
        // The vacated region is asked of the parent, because it is expressed
        // in the parent's coordinate space -- which is what arrangedRect is.
        if (_arrangedRect != vacated)
        {
            invalidateVisual();

            if (_parent !is null && !vacated.empty)
                _parent.invalidateVisual(vacated);
        }

        if (arranged.width != previous.width || arranged.height != previous.height)
            raiseEvent(new SizeChangedEventArgs(sizeChangedEvent, previous, arranged));
    }

   /**
    * The size this element asked for at the last measure.
    */
    @property Size desiredSize() const pure nothrow @nogc
    {
        return _desiredSize;
    }

   /**
    * What the content needed at the last measure, before the room on offer was
    * allowed to cut it down, and without the margin.
    *
    * desiredSize is what the parent is told, and it is capped at what the
    * parent offered so that a panel adding its children up adds up sizes that
    * fit.  This is the number that got capped.  It is what arrange goes back
    * to when the element is not being stretched, which is why an element that
    * does not fit overflows its slot rather than being squeezed into it.
    */
    @property Size unclippedDesiredSize() const pure nothrow @nogc
    {
        return _unclippedDesiredSize;
    }

   /**
    * Whether the measured size is up to date.  False from the moment
    * invalidateMeasure is called until a pass has answered it.
    */
    @property bool isMeasureValid() const pure nothrow @nogc
    {
        return !_measureDirty;
    }

    /// ditto
    @property bool isArrangeValid() const pure nothrow @nogc
    {
        return !_arrangeDirty;
    }

   /**
    * Marks the measured size as out of date, and the placement with it: a size
    * that has to be worked out again has to be placed again.
    *
    * Travels up the tree, because a child that may want a different size
    * changes what its parent wants.  The walk stops at the first ancestor
    * already marked -- whatever marked it walked the rest of the chain then --
    * which is what keeps invalidating a whole subtree linear rather than
    * quadratic.
    */
    void invalidateMeasure()
    {
        immutable wasDirty = _measureDirty;
        _measureDirty = true;

        // Registered every time, not only on the way from valid to invalid.
        // Being marked and being queued are two different things: a pass that
        // failed leaves elements marked with nothing queued, and an element
        // that could not put itself back would never be laid out again.  A
        // repeat entry costs an array slot and is skipped in a comparison.
        if (auto manager = layoutManager)
            manager.enqueueMeasure(this);

        invalidateArrange();

        // The walk up is what stays guarded: an ancestor already marked was
        // walked past when it was marked, so stopping there keeps invalidating
        // a subtree linear rather than quadratic.  Nothing is lost by it, since
        // the pass climbs to the top of the marked chain before it starts.
        if (!wasDirty && _parent !is null)
            _parent.invalidateMeasure();
    }

   /**
    * Marks the placement as out of date, leaving the measured size alone.
    *
    * Unlike measure this does not travel: where a child ends up does not
    * change where its parent is.
    */
    void invalidateArrange()
    {
        _arrangeDirty = true;

        if (auto manager = layoutManager)
            manager.enqueueArrange(this);
    }

   /**
    * Settles whatever layout is outstanding now, instead of waiting for the
    * pass the dispatcher has queued.
    *
    * Everything out of date on this thread is settled, not this element's
    * subtree alone: an element cannot be sure of its own size while something
    * above it is still undecided.
    *
    * Called from inside a pass this does nothing, because the pass it would
    * start is the one it is being called from.
    */
    final void updateLayout()
    {
        verifyAccess();

        if (auto manager = layoutManager)
            manager.updateLayout();
    }

   /**
    * Measures this element as the top of a layout pass -- the highest one that
    * is out of date, with nothing above it left to say how much room there is.
    *
    * The last question it was asked is the best answer available: whatever
    * space its parent offered before is the space it still has, or the parent
    * would be out of date too and the pass would have started higher up.
    *
    * An element whose size is dictated from outside the tree overrides this to
    * say where its room really comes from.  Window does, because the platform
    * tells it; a popup or an adorner layer would for the same reason.
    */
    void measureAsRoot()
    {
        measure(_previousConstraint);
    }

    /// ditto
    void arrangeAsRoot()
    {
        arrange(_arrangeSlot);
    }

   /**
    * The visual tree, answered from the element tree.
    *
    * Today the two are the same tree, so these three are one line each.  The
    * seam is what makes that a statement rather than an assumption: when
    * control templates arrive and a button's parts become visual children of
    * the button and logical children of nobody, the answers change here and
    * nothing that walks the visual tree notices.
    */
    override @property Visual visualParent()
    {
        return _parent;
    }

    /// ditto
    override @property size_t visualChildCount()
    {
        return _children.length;
    }

    /// ditto
    override Visual visualChild(size_t index)
    {
        return _children[index];
    }

   /**
    * Asks for every mouse event to come here until the capture is given up,
    * wherever the pointer actually is.
    *
    * What a button needs to survive being pressed, dragged off itself and
    * released somewhere else: without it the release lands on whatever is
    * under the pointer and the button is never told it is no longer pressed.
    *
    * The request travels to the top of the tree, because holding the pointer is
    * something a surface does and an element in no surface cannot do it -- the
    * same shape as repaintAsRoot, and for the same reason: element.d may not
    * name Window.
    *
    * A capture can end without being released here.  The system takes it away
    * when a menu opens, when another window is shown, on a task switch; that is
    * what mouseCaptureLost is for, and an element that undoes its state only in
    * releaseMouseCapture will one day be left holding it.
    */
    void captureMouse()
    {
        root.captureAsRoot(this);
    }

    /// ditto
    void releaseMouseCapture()
    {
        root.releaseCaptureAsRoot(this);
    }

   /**
    * Whether every mouse event is coming here at the moment.
    *
    * A plain flag rather than a property: nothing styles on it, and the
    * elements that read it are the ones that asked for it.  It becomes a
    * read-only property the day a template wants to.
    */
    @property bool isMouseCaptured() const pure nothrow @nogc
    {
        return _mouseCaptured;
    }

   /**
    * Takes or gives up the pointer on behalf of an element below.
    *
    * The default does nothing, which is the right answer for a tree with no
    * surface under it -- there is nothing to hold the pointer with.  Window
    * overrides both.
    */
    void captureAsRoot(Element target)
    {
    }

    /// ditto
    void releaseCaptureAsRoot(Element target)
    {
    }

package:
   /*
    * Records that this element is or is not holding the pointer.  Written by
    * the surface that grants it and by nothing else.
    */
    void setMouseCaptured(bool value) pure nothrow @nogc
    {
        _mouseCaptured = value;
    }

   /*
    * Records that the pointer is or is not over this element.
    *
    * The write side of isMouseOver, and the reason the key stays private: the
    * input code in this package is the only thing that knows where the pointer
    * is, and possession of the key is the permission to say so.
    */
    void setMouseOver(bool value)
    {
        setValue(isMouseOverKey, Value(value));
    }

protected:
   /**
    * Puts a repaint request on the layout pass's queue.
    *
    * The layer above knows it wants to be drawn again and deliberately does not
    * know where such a request goes -- see the banner in visual.d for what that
    * separation is worth.  This is where it goes: the same pass that measures
    * and arranges, so that "laid out, then repainted" is true by construction.
    */
    override void enqueueRepaint(Rect region, bool hasRegion)
    {
        auto manager = layoutManager;
        if (manager is null)
            return;

        if (hasRegion)
            manager.enqueueVisual(this, region);
        else
            manager.enqueueVisual(this);
    }

   /**
    * Measures the content and reports the size it wants.  The default offers
    * every child the whole of the available space and asks for the largest
    * answer back -- a single-cell container, which is what an element with no
    * layout of its own amounts to.  Panels override this.
    */
    Size measureOverride(Size availableSize)
    {
        Size desired;

        foreach (child; _children)
        {
            child.measure(availableSize);

            if (child._desiredSize.width > desired.width)
                desired.width = child._desiredSize.width;
            if (child._desiredSize.height > desired.height)
                desired.height = child._desiredSize.height;
        }

        return desired;
    }

   /**
    * Places the children and reports the size actually taken.  The default
    * hands every child the whole rectangle, to match measureOverride.
    */
    Size arrangeOverride(Size finalSize)
    {
        foreach (child; _children)
            child.arrange(Rect(0, 0, finalSize.width, finalSize.height));

        return finalSize;
    }

   /**
    * Turns a property change into layout invalidation, as the property's
    * metadata asked for.
    *
    * This is what the affectsMeasure family is for, and what makes
    * `element.width = 200` mean something: the flags are declared once at
    * registration and every element honours them, whichever module registered
    * the property.
    *
    * Note that arrange() writes ActualWidth and ActualHeight and so arrives
    * here on every pass.  Neither carries a flag, and neither may.  A property
    * written by arranging that invalidated arranging would never settle, and
    * only the pass limit would catch it; affectsRender on either would be
    * quieter and no better -- it would re-arm the render queue from inside
    * the pass on every frame that changed a size, bypassing the check on the
    * rectangle actually having moved, and the coalescing would never get a
    * turn.
    */
    override void onPropertyChanged(immutable(Property) property,
                                    ref immutable(PropertyMetadata) metadata,
                                    const(Value) oldValue,
                                    const(Value) newValue)
    {
        super.onPropertyChanged(property, metadata, oldValue, newValue);

        // Measure subsumes arrange, so the cheaper request is only worth
        // making when the dearer one was not.
        if (metadata.affectsMeasure)
            invalidateMeasure();
        else if (metadata.affectsArrange)
            invalidateArrange();

        if (_parent !is null)
        {
            if (metadata.affectsParentMeasure)
                _parent.invalidateMeasure();
            else if (metadata.affectsParentArrange)
                _parent.invalidateArrange();
        }

        // Independent of the two above rather than another else-if.  Measure
        // subsumes arrange because working a size out again means placing it
        // again, but neither implies redrawing at the level of a flag, and a
        // property is entitled to claim both honestly.
        if (metadata.affectsRender)
            invalidateVisual();
    }

   /**
    * Called on the element right after it has been added to a parent.
    * Inherited-property and style invalidation will hook in here later.
    */
    void onAttached(Element parent)
    {
    }

   /**
    * Called on the element right after it has been removed from a parent.
    */
    void onDetached(Element oldParent)
    {
    }

private:
   /*
    * The one width range and the one height range an element may end up in,
    * from Width, Height and the four bounds together.
    *
    * They are not rivals.  A width of its own collapses the range onto itself;
    * an unset one leaves it floored at the minimum and open up to the maximum.
    * That collapse is what keeps the old behaviour intact: with a Width set,
    * minWidth and maxWidth are both that width, so clamping against the range
    * replaces the offered constraint exactly as the plain assignment used to.
    *
    * The two lines per axis apply the maximum to the width first and the
    * minimum last, which is what makes a MinWidth of 300 beat a MaxWidth of
    * 100 instead of leaving a range nothing can satisfy.
    */
   /*
    * How far into the room the element starts.
    *
    * Stretch degenerates rather than being a fourth case.  An element bigger
    * than the room cannot be stretched into it, and starting it at the near
    * edge means what gets cut off is the far side rather than both; one that
    * is smaller and still could not stretch -- because a width of its own or a
    * maximum stopped it -- ends up centred, which is what the arithmetic below
    * already says.
    *
    * Two functions rather than one because the two enums name their members
    * differently, and matching them by ordinal instead is the kind of coupling
    * that breaks in silence.  final switch makes a new member a compile error
    * here rather than a wrong answer at run time.
    */
    static float horizontalOffset(HorizontalAlignment alignment, float room, float taken)
    {
        final switch (alignment)
        {
            case HorizontalAlignment.left:    return 0;
            case HorizontalAlignment.center:  return (room - taken) * 0.5f;
            case HorizontalAlignment.right:   return room - taken;
            case HorizontalAlignment.stretch: return taken > room ? 0 : (room - taken) * 0.5f;
        }
    }

    /// ditto
    static float verticalOffset(VerticalAlignment alignment, float room, float taken)
    {
        final switch (alignment)
        {
            case VerticalAlignment.top:     return 0;
            case VerticalAlignment.center:  return (room - taken) * 0.5f;
            case VerticalAlignment.bottom:  return room - taken;
            case VerticalAlignment.stretch: return taken > room ? 0 : (room - taken) * 0.5f;
        }
    }

    static struct MinMax
    {
        this(Element e)
        {
            maxWidth = e.maxWidth;
            minWidth = e.minWidth;
            maxWidth = atLeast(atMost(e.isWidthSet ? e.width : float.infinity, maxWidth), minWidth);
            minWidth = atLeast(atMost(e.isWidthSet ? e.width : 0.0f,           maxWidth), minWidth);

            maxHeight = e.maxHeight;
            minHeight = e.minHeight;
            maxHeight = atLeast(atMost(e.isHeightSet ? e.height : float.infinity, maxHeight), minHeight);
            minHeight = atLeast(atMost(e.isHeightSet ? e.height : 0.0f,           maxHeight), minHeight);
        }

        float minWidth;
        float maxWidth;
        float minHeight;
        float maxHeight;
    }

   /*
    * The layout pass this element belongs to, which is the one belonging to
    * the dispatcher it is bound to.
    */
    LayoutManager layoutManager()
    {
        return LayoutManager.forCurrentThread();
    }

   /*
    * Marks an element that has just left the tree.
    *
    * The flags alone, with no queue entry: an element with no parent has no
    * rectangle to be placed in and nothing to be measured against, so a pass
    * has nowhere to put it.  Being marked is what makes it lay itself out
    * properly when it joins a tree again -- and joining one invalidates the
    * new parent, which is what brings the pass down to it.
    */
    void markLayoutDirty() pure nothrow @nogc
    {
        _measureDirty = true;
        _arrangeDirty = true;

        // The visual mark is deliberately not set here.  An element that has
        // just left the tree is in no surface, so there is nothing to repaint
        // -- and unlike layout there is no way back: rejoining a tree
        // invalidates the new parent's measure, which brings a pass down to
        // the child, but nothing corresponding would ever clear a visual mark
        // left here.  It would stick for the life of the element.
    }

   /*
    * Invokes the handlers this element runs for the args' event, respecting
    * the handled flag.  Iterates a snapshot of the handler list, so
    * handlers may add or remove handlers while the event is delivered.
    *
    * The class tier goes first, whatever this element's own list holds: what a
    * control is made of does not queue up behind what somebody asked to hear
    * about.  The early return below is under it for that reason -- an element
    * nobody subscribed to still has a type, and the type may have plenty to say.
    */
    void invokeLocalHandlers(RoutedEventArgs args)
    {
        invokeClassHandlers(this, args);

        auto list = args.routedEvent.id in _handlers;
        if (list is null)
            return;

        foreach (entry; *list)
        {
            if (!args.handled || entry.handledEventsToo)
                entry.handler(this, args);
        }
    }

    struct HandlerEntry
    {
        RoutedEventHandler handler;
        bool handledEventsToo;
    }

    // Written only by the shared static constructor above.  Private because
    // the key is the write permission for the actual size: publishing it would
    // let anyone claim an element is a size it was never arranged at.
    static immutable(ReadOnlyPropertyKey) actualWidthKey;
    static immutable(ReadOnlyPropertyKey) actualHeightKey;
    static immutable(ReadOnlyPropertyKey) isMouseOverKey;

    Element              _parent;
    Element[]            _children;
    HandlerEntry[][uint] _handlers;
    // What the parent is told this element costs: the content's size, bounded,
    // plus the margin, and never more than the parent offered.
    Size                 _desiredSize;
    // What the content actually needed, before the offer above was allowed to
    // cut it down, and with the margin excluded so it lines up directly with
    // the slot-less-margin arrange works in.  arrange goes back to this
    // whenever the element is not being stretched: the clipped size is what
    // the parent could spare, which is not the same as what was wanted.
    Size                 _unclippedDesiredSize;
    // The availableSize the last measure that ran was given, as it arrived --
    // before Width and Height are laid over it, since that is what the next
    // caller's availableSize gets compared against.
    Size                 _previousConstraint;
    // The rectangle the parent handed down, which is not where the element
    // ends up once a margin and an alignment have had their say.  This is what
    // the early-out compares against and what arrangeAsRoot passes again:
    // going back to the placement instead would let a right-aligned element
    // walk across its slot, one pass at a time.
    Rect                 _arrangeSlot;
    bool                 _measureDirty = true;
    bool                 _arrangeDirty = true;
    bool                 _mouseCaptured;
}

/*
 * The two clamps layout spends its time in, named for what they mean rather
 * than for which way round the comparison goes.
 *
 * Written as comparisons rather than through std.algorithm so that an infinite
 * ceiling costs one test and nothing else: `value > infinity` is false, so a
 * maximum nobody set drops straight out.
 */
private float atLeast(float value, float floor) pure nothrow @nogc
{
    return value < floor ? floor : value;
}

/// ditto
private float atMost(float value, float ceiling) pure nothrow @nogc
{
    return value > ceiling ? ceiling : value;
}

/*
 * A length a margin may have driven below zero.
 *
 * Spelled `> 0` rather than as atLeast(value, 0) on purpose: this sits at the
 * outer edge of the arithmetic, and a NaN arriving from somewhere comes out of
 * here as zero instead of travelling on into a constraint, where it would
 * defeat the measure early-out for good.
 */
private float notBelowZero(float value) pure nothrow @nogc
{
    return value > 0 ? value : 0;
}

/**
 * Carries the size an element had and the size it has now.
 *
 * Both are given because a handler almost always wants the difference: a
 * renderer that scales, a scroll viewer that re-clamps its offset, a log that
 * says what changed.  Recomputing it from the element alone is impossible --
 * by the time the handler runs, the old size is gone.
 */
class SizeChangedEventArgs : RoutedEventArgs
{
    this(immutable(RoutedEvent) routedEvent, Size previousSize, Size newSize)
    {
        super(routedEvent);

        _previousSize = previousSize;
        _newSize = newSize;
    }

   /**
    * The size the element was arranged at before this pass.
    */
    @property Size previousSize() const pure nothrow @nogc
    {
        return _previousSize;
    }

   /**
    * The size it has been arranged at now.
    */
    @property Size newSize() const pure nothrow @nogc
    {
        return _newSize;
    }

   /**
    * Whether that dimension is the one that changed.  An element that only
    * grew taller raises the event with widthChanged false.
    */
    @property bool widthChanged() const pure nothrow @nogc
    {
        return _previousSize.width != _newSize.width;
    }

    /// ditto
    @property bool heightChanged() const pure nothrow @nogc
    {
        return _previousSize.height != _newSize.height;
    }

private:
    Size _previousSize;
    Size _newSize;
}

/**
 * Read-only, indexable forward range over an element's children.
 */
struct ChildrenView
{
    @property size_t length() const pure nothrow @nogc
    {
        return _items.length;
    }

    @property bool empty() const pure nothrow @nogc
    {
        return _items.length == 0;
    }

    @property Element front() pure nothrow @nogc
    {
        return _items[0];
    }

    void popFront() pure nothrow @nogc
    {
        _items = _items[1 .. $];
    }

    @property ChildrenView save() pure nothrow @nogc
    {
        return this;
    }

    Element opIndex(size_t index) pure nothrow @nogc
    {
        return _items[index];
    }

    size_t opDollar() const pure nothrow @nogc
    {
        return _items.length;
    }

    private Element[] _items;
}

/**
 * Forward range over an element's ancestors, nearest first.
 */
struct AncestorRange
{
    @property bool empty() const pure nothrow @nogc
    {
        return _current is null;
    }

    @property Element front() pure nothrow @nogc
    {
        return _current;
    }

    void popFront() pure nothrow @nogc
    {
        _current = _current._parent;
    }

    @property AncestorRange save() pure nothrow @nogc
    {
        return this;
    }

    private Element _current;
}

/**
 * Input range performing a depth-first pre-order walk of a subtree.
 */
struct DescendantRange
{
    @property bool empty() const pure nothrow @nogc
    {
        return _stack.length == 0;
    }

    @property Element front() pure nothrow @nogc
    {
        return _stack[$ - 1];
    }

    void popFront() pure nothrow
    {
        auto node = _stack[$ - 1];
        _stack = _stack[0 .. $ - 1];

        foreach_reverse (child; node._children)
            _stack ~= child;
    }

    private Element[] _stack;
}

unittest
{
    import std.exception : assertThrown;
    import std.algorithm : equal;

    auto root = new Element;
    auto a = new Element;
    auto b = new Element;
    auto c = new Element;

    root.addChild(a);
    root.addChild(b);
    a.addChild(c);

    // Structure
    assert(root.parent is null);
    assert(a.parent is root);
    assert(b.parent is root);
    assert(c.parent is a);
    assert(root.childCount == 2);
    assert(root.children[0] is a);
    assert(root.children[1] is b);
    assert(root.children[$ - 1] is b);
    assert(c.root is root);
    assert(root.root is root);

    // Invariants
    assertThrown(root.addChild(null));   // null child
    assertThrown(root.addChild(a));      // already a child of this element
    assertThrown(b.addChild(a));         // already parented elsewhere
    assertThrown(c.addChild(root));      // would create a cycle
    {
        auto solo = new Element;
        assertThrown(solo.addChild(solo)); // self as child
    }
    assertThrown(root.removeChild(c));   // not a direct child
    assertThrown(root.removeChild(null));

    // Traversal
    assert(c.ancestors.equal([a, root]));
    assert(root.ancestors.empty);
    assert(root.descendants.equal([a, c, b])); // depth-first pre-order
    assert(c.descendants.empty);

    // Ancestry predicates
    assert(root.isAncestorOf(c));
    assert(root.isAncestorOf(a));
    assert(!c.isAncestorOf(root));
    assert(!root.isAncestorOf(root));
    assert(c.isDescendantOf(root));
    assert(!root.isDescendantOf(c));
    assert(!root.isAncestorOf(null));

    // Removal clears the parent link but keeps the child's subtree
    root.removeChild(b);
    assert(b.parent is null);
    assert(root.childCount == 1);
    assert(c.parent is a); // untouched

    // detach()
    c.detach();
    assert(c.parent is null);
    assert(a.childCount == 0);
    c.detach(); // no-op on a root

    // insertChild ordering
    root.insertChild(0, b);
    assert(root.children[0] is b);
    assert(root.children[1] is a);
    assertThrown(root.insertChild(5, c)); // index out of range

    // clearChildren detaches every child
    root.addChild(c);
    root.clearChildren();
    assert(root.childCount == 0);
    assert(a.parent is null);
    assert(b.parent is null);
    assert(c.parent is null);
}

unittest
{
    // Attach/detach hooks fire after the state change, with the right peer.
    static class Probe : Element
    {
        int attachedCount;
        int detachedCount;
        Element seenParent;
        Element seenOldParent;
        bool parentWasSetInHook;

        protected override void onAttached(Element parent)
        {
            attachedCount++;
            seenParent = parent;
            parentWasSetInHook = (this.parent is parent);
        }

        protected override void onDetached(Element oldParent)
        {
            detachedCount++;
            seenOldParent = oldParent;
        }
    }

    auto host = new Element;
    auto probe = new Probe;

    host.addChild(probe);
    assert(probe.attachedCount == 1);
    assert(probe.seenParent is host);
    assert(probe.parentWasSetInHook); // state updated before the hook runs

    host.removeChild(probe);
    assert(probe.detachedCount == 1);
    assert(probe.seenOldParent is host);
    assert(probe.parent is null);

    host.addChild(probe);
    probe.detach();
    assert(probe.attachedCount == 2);
    assert(probe.detachedCount == 2);

    // clearChildren also fires the hook
    host.addChild(probe);
    host.clearChildren();
    assert(probe.detachedCount == 3);
}

unittest
{
    import cherry.core.property;
    import cherry.core.rtti;
    import cherry.core.value;

    static class Label : Element
    {
    }

    PropertyMetadata inheritingMeta;
    inheritingMeta.defaultValue = Value(10);
    inheritingMeta.inherits = true;
    auto sizeProperty = Property.register("InheritedSize", getRtti!int(), getRtti!Label(), inheritingMeta);

    PropertyMetadata plainMeta;
    plainMeta.defaultValue = Value(7);
    auto plainProperty = Property.register("PlainSize", getRtti!int(), getRtti!Label(), plainMeta);

    auto root  = new Element;
    auto panel = new Element;
    auto label = new Label;
    root.addChild(panel);
    panel.addChild(label);

    // Nothing set anywhere: the element's own effective default.
    assert(label.getValue(sizeProperty).get!int == 10);

    // A value on a distant ancestor is inherited across levels.
    root.setValue(sizeProperty, Value(20));
    assert(label.getValue(sizeProperty).get!int == 20);
    assert(!label.hasLocalValue(sizeProperty));

    // The nearest ancestor wins.
    panel.setValue(sizeProperty, Value(30));
    assert(label.getValue(sizeProperty).get!int == 30);

    // A local value beats inheritance; ancestors are unaffected.
    label.setValue(sizeProperty, Value(40));
    assert(label.getValue(sizeProperty).get!int == 40);
    assert(panel.getValue(sizeProperty).get!int == 30);

    // Clearing the local value falls back to inheritance.
    label.clearValue(sizeProperty);
    assert(label.getValue(sizeProperty).get!int == 30);

    // A valueless ancestor is skipped, not treated as a source.
    panel.clearValue(sizeProperty);
    assert(label.getValue(sizeProperty).get!int == 20);

    // Detaching the subtree cuts the inheritance chain...
    panel.detach();
    assert(label.getValue(sizeProperty).get!int == 10);

    // ...and re-attaching restores it.
    root.addChild(panel);
    assert(label.getValue(sizeProperty).get!int == 20);

    // Non-inheriting properties never flow down the tree.
    root.setValue(plainProperty, Value(99));
    assert(label.getValue(plainProperty).get!int == 7);
}

unittest
{
    import cherry.platform.render : RecordingContext;

    // The render walk visits the subtree in depth-first pre-order, so
    // parents paint under their children.
    static string[] renderLog;

    static class Painter : Element
    {
        string tag;

        this(string tag)
        {
            this.tag = tag;
        }

        protected override void onRender(DrawingContext context)
        {
            renderLog ~= tag;
        }
    }

    auto root = new Painter("root");
    auto a = new Painter("a");
    auto b = new Painter("b");
    auto c = new Painter("c");
    root.addChild(a);
    root.addChild(b);
    a.addChild(c);

    renderLog = null;
    root.renderSubtree(new RecordingContext);
    assert(renderLog == ["root", "a", "c", "b"]);
}

unittest
{
    import std.math : isNaN;

    // A size starts out unset.  "No width of my own" is a state rather than a
    // number, and it is the one every element begins in.
    auto element = new Element;

    assert(!element.isWidthSet);
    assert(!element.isHeightSet);
    assert(element.width.isNaN, "an unset width reads as NaN at the boundary");
    assert(element.getValue(Element.widthProperty).empty, "and as nothing at all in the store");

    element.width = 120;
    assert(element.isWidthSet);
    assert(element.width == 120);

    element.clearValue(Element.widthProperty);
    assert(!element.isWidthSet, "clearing hands the decision back to the layout");
    assert(element.width.isNaN);
}

unittest
{
    // Measure: an element with nothing in it asks for nothing, and a size of
    // its own is a demand rather than a preference.
    auto bare = new Element;
    bare.measure(Size(500, 400));
    assert(bare.desiredSize == Size(0, 0));
    assert(bare.unclippedDesiredSize == Size(0, 0));

    auto sized = new Element;
    sized.width = 200;
    sized.height = 100;
    sized.measure(Size(500, 400));
    assert(sized.desiredSize == Size(200, 100));
    assert(sized.unclippedDesiredSize == Size(200, 100),
           "it fitted, so there is nothing for the two to disagree about");

    // One that does not fit is not told it fits, and neither is its parent.
    // What comes back can never exceed what was offered, so a panel adding its
    // children up is adding up sizes that fit in the room it has -- and the
    // demand is not lost, it is on the record next door, which is where
    // arrange goes to find it.
    sized.width = 900;
    sized.measure(Size(500, 400));
    assert(sized.desiredSize.width == 500, "the parent hears only what it offered");
    assert(sized.unclippedDesiredSize.width == 900, "and what was really wanted survives");
    assert(sized.desiredSize.height == 100, "the axis that fitted is untouched");
}

unittest
{
    // What an element is measured against: its own size where it has one, and
    // what the parent offered everywhere else.
    static class Probe : Element
    {
        Size seenAvailable;

        protected override Size measureOverride(Size availableSize)
        {
            seenAvailable = availableSize;
            return Size(0, 0);
        }
    }

    auto probe = new Probe;

    probe.measure(Size(500, 400));
    assert(probe.seenAvailable == Size(500, 400), "with no size of its own, all of it");

    probe.width = 200;
    probe.measure(Size(500, 400));
    assert(probe.seenAvailable == Size(200, 400), "the width it demanded, the height it was offered");
}

unittest
{
    // An element with no layout of its own asks for as much as its largest
    // child needs -- in each dimension separately, so two children can each
    // decide one of them.
    auto parent = new Element;
    auto tall = new Element;
    auto wide = new Element;

    tall.width = 50;
    tall.height = 300;
    wide.width = 200;
    wide.height = 80;

    parent.addChild(tall);
    parent.addChild(wide);
    parent.measure(Size(1000, 1000));

    assert(parent.desiredSize == Size(200, 300));
}

unittest
{
    import std.exception : assertThrown;

    // Arrange settles the actual size, and nothing else may: the key lives
    // inside Element, so the property reads everywhere and writes nowhere.
    auto element = new Element;
    assert(element.actualWidth == 0 && element.actualHeight == 0);

    element.arrange(Rect(10, 20, 300, 150));

    assert(element.actualWidth == 300);
    assert(element.actualHeight == 150);
    assert(element.arrangedRect == Rect(10, 20, 300, 150));

    assertThrown(element.setValue(Element.actualWidthProperty, Value(999.0f)));
    assert(element.actualWidth == 300);
}

unittest
{
    // onSizeChanged reports a change, only a change, and only its own.
    auto parent = new Element;
    auto child = new Element;
    parent.addChild(child);

    int parentSeen;
    int childSeen;
    SizeChangedEventArgs last;

    parent.onSizeChanged ~= (Element sender, RoutedEventArgs args) {
        parentSeen++;
        last = cast(SizeChangedEventArgs) args;
    };
    child.onSizeChanged ~= (Element sender, RoutedEventArgs args) { childSeen++; };

    parent.arrange(Rect(0, 0, 200, 100));
    assert(parentSeen == 1);
    assert(last.previousSize == Size(0, 0));
    assert(last.newSize == Size(200, 100));
    assert(last.widthChanged && last.heightChanged);
    assert(childSeen == 1, "the default arrange passes the whole rectangle down");

    // The same size again is not news.
    parent.arrange(Rect(0, 0, 200, 100));
    assert(parentSeen == 1);
    assert(childSeen == 1);

    // One dimension moving is reported as one dimension moving.
    parent.arrange(Rect(0, 0, 200, 130));
    assert(parentSeen == 2);
    assert(!last.widthChanged && last.heightChanged);
    assert(last.previousSize == Size(200, 100) && last.newSize == Size(200, 130));

    // And the event is direct: a child resizing is the child's business, so
    // it does not travel up to a parent that did not resize.
    auto parentBefore = parentSeen;
    child.arrange(Rect(0, 0, 40, 40));
    assert(childSeen == 3, "the two parent passes that moved it, and this one");
    assert(parentSeen == parentBefore);
}

version (unittest)
{
   /*
    * Counts the passes it is put through, which is how the tests below tell
    * work that was done from work that was skipped.
    */
    private static class Counter : Element
    {
        int measures;
        int arranges;

        protected override Size measureOverride(Size availableSize)
        {
            measures++;
            return super.measureOverride(availableSize);
        }

        protected override Size arrangeOverride(Size finalSize)
        {
            arranges++;
            return super.arrangeOverride(finalSize);
        }
    }
}

unittest
{
    // Measuring is skipped when it is clean and the question has not changed,
    // which is the whole economy of an incremental pass.
    auto c = new Counter;

    c.measure(Size(500, 400));
    assert(c.measures == 1);

    c.measure(Size(500, 400));
    assert(c.measures == 1, "same question, same answer, nobody asked again");

    // A different question has to be put, clean or not.
    c.measure(Size(300, 400));
    assert(c.measures == 2);

    // And a dirty element answers again even to the question it just answered.
    c.invalidateMeasure();
    c.measure(Size(300, 400));
    assert(c.measures == 3);
}

unittest
{
    // Arranging skips on the same terms, and both halves of the rule are load
    // bearing: clean alone would refuse to move an element, the same rectangle
    // alone would refuse to re-place one whose content changed.
    auto c = new Counter;

    c.arrange(Rect(0, 0, 200, 100));
    assert(c.arranges == 1);

    c.arrange(Rect(0, 0, 200, 100));
    assert(c.arranges == 1, "clean, and nowhere new to go");

    c.arrange(Rect(0, 0, 200, 130));
    assert(c.arranges == 2, "clean, but somewhere new to go");

    c.invalidateArrange();
    c.arrange(Rect(0, 0, 200, 130));
    assert(c.arranges == 3, "nowhere new to go, but something changed underneath");
}

unittest
{
    // Invalidating a measure travels up: a child that may want a different
    // size changes what its parent wants.  Invalidating an arrange does not --
    // where a child ends up does not move its parent.
    auto root = new Element;
    auto middle = new Element;
    auto leaf = new Element;
    root.addChild(middle);
    middle.addChild(leaf);

    root.measure(Size(500, 400));
    root.arrange(Rect(0, 0, 500, 400));
    assert(root.isMeasureValid && middle.isMeasureValid && leaf.isMeasureValid);
    assert(root.isArrangeValid && middle.isArrangeValid && leaf.isArrangeValid);

    leaf.invalidateMeasure();
    assert(!leaf.isMeasureValid && !middle.isMeasureValid && !root.isMeasureValid);
    assert(!leaf.isArrangeValid, "a size to work out again is a size to place again");
    assert(!middle.isArrangeValid && !root.isArrangeValid);

    root.measure(Size(500, 400));
    root.arrange(Rect(0, 0, 500, 400));

    leaf.invalidateArrange();
    assert(!leaf.isArrangeValid);
    assert(middle.isArrangeValid && root.isArrangeValid, "and it stops there");
    assert(leaf.isMeasureValid, "the size it asked for is still the size it asks for");
}

unittest
{
    // The invariant the arrange skip rests on: measuring settles the size and
    // nothing else, so an element that has been measured is still waiting to
    // be placed.
    auto e = new Element;
    e.measure(Size(500, 400));

    assert(e.isMeasureValid);
    assert(!e.isArrangeValid, "measuring never says where anything goes");
}

unittest
{
    // What the affectsMeasure family is for: the flags are declared once at
    // registration and every element honours them.
    static class Flagged : Element
    {
        shared static this()
        {
            PropertyMetadata measureMeta;
            measureMeta.defaultValue = Value(0);
            measureMeta.affectsMeasure = true;

            PropertyMetadata arrangeMeta;
            arrangeMeta.defaultValue = Value(0);
            arrangeMeta.affectsArrange = true;

            PropertyMetadata plainMeta;
            plainMeta.defaultValue = Value(0);

            sizingProperty = Property.register("Sizing", getRtti!int(), getRtti!Flagged(), measureMeta);
            placingProperty = Property.register("Placing", getRtti!int(), getRtti!Flagged(), arrangeMeta);
            idleProperty = Property.register("Idle", getRtti!int(), getRtti!Flagged(), plainMeta);
        }

        static immutable(Property) sizingProperty;
        static immutable(Property) placingProperty;
        static immutable(Property) idleProperty;
    }

    auto parent = new Element;
    auto e = new Flagged;
    parent.addChild(e);

    // Puts the pair back into a known clean state.  Both are invalidated
    // first, because a clean parent stops at its own early-out and never
    // reaches a dirty child -- which is exactly why a layout pass starts at
    // the topmost element that is out of date rather than at the root.
    void settle()
    {
        e.invalidateMeasure();
        parent.measure(Size(500, 400));
        parent.arrange(Rect(0, 0, 500, 400));
        assert(parent.isMeasureValid && parent.isArrangeValid);
        assert(e.isMeasureValid && e.isArrangeValid);
    }

    settle();
    e.setValue(Flagged.sizingProperty, Value(1));
    assert(!e.isMeasureValid && !e.isArrangeValid);
    assert(!parent.isMeasureValid, "and the parent hears about it");

    settle();
    e.setValue(Flagged.placingProperty, Value(1));
    assert(e.isMeasureValid, "placing it somewhere else does not resize it");
    assert(!e.isArrangeValid);
    assert(parent.isArrangeValid, "and its parent stays where it is");

    settle();
    e.setValue(Flagged.idleProperty, Value(1));
    assert(e.isMeasureValid && e.isArrangeValid, "a property that claims nothing costs nothing");

    // Width carries affectsMeasure, which is what makes assigning one mean
    // something at all.
    settle();
    e.width = 200;
    assert(!e.isMeasureValid && !parent.isMeasureValid);

    // And so does taking it away again.
    settle();
    e.clearValue(Element.widthProperty);
    assert(!e.isMeasureValid, "reverting a size is a size change like any other");
}

unittest
{
    // A tree that changes shape has to be laid out again: what a parent asks
    // for is worked out from its children, so the set of them is an input.
    auto parent = new Element;
    auto first = new Element;
    auto second = new Element;

    void settle()
    {
        first.invalidateMeasure();
        second.invalidateMeasure();
        parent.invalidateMeasure();
        parent.measure(Size(500, 400));
        parent.arrange(Rect(0, 0, 500, 400));
    }

    parent.addChild(first);
    settle();
    assert(parent.isMeasureValid);

    parent.addChild(second);
    assert(!parent.isMeasureValid, "one more child to account for");
    assert(!second.isMeasureValid, "and it has never been measured under this parent");

    settle();
    parent.removeChild(second);
    assert(!parent.isMeasureValid, "one fewer");

    settle();
    parent.clearChildren();
    assert(!parent.isMeasureValid);

    // Clearing nothing changes nothing.
    settle();
    parent.clearChildren();
    assert(parent.isMeasureValid);
}

unittest
{
    // An element that leaves the tree is marked, but has nowhere to be laid
    // out until it joins one again -- and joining one is what brings a pass
    // down to it.
    auto parent = new Element;
    auto child = new Element;
    parent.addChild(child);

    parent.measure(Size(500, 400));
    parent.arrange(Rect(0, 0, 500, 400));
    assert(child.isMeasureValid && child.isArrangeValid);

    parent.removeChild(child);
    assert(!child.isMeasureValid && !child.isArrangeValid);

    // Back in, and measured again under whoever has it now.
    auto adopter = new Element;
    adopter.addChild(child);
    adopter.measure(Size(120, 90));
    adopter.arrange(Rect(0, 0, 120, 90));

    assert(child.isMeasureValid && child.isArrangeValid);
    assert(child.arrangedRect == Rect(0, 0, 120, 90));
}

unittest
{
    // An enum-typed property, which is a first for this framework: the RTTI of
    // an enum is that enum and nothing else, so the integer behind it will not
    // do -- exactly as in D itself.
    import std.exception : assertThrown;

    auto e = new Element;

    assert(e.horizontalAlignment == HorizontalAlignment.stretch,
           "the default the registration declared, which is not the enum's own .init");
    assert(HorizontalAlignment.init == HorizontalAlignment.left,
           "those two differ on purpose");
    assert(e.getValue(Element.horizontalAlignmentProperty).get!HorizontalAlignment
           == HorizontalAlignment.stretch);

    e.horizontalAlignment = HorizontalAlignment.right;
    assert(e.horizontalAlignment == HorizontalAlignment.right);
    assert(e.hasLocalValue(Element.horizontalAlignmentProperty));

    assertThrown(e.setValue(Element.horizontalAlignmentProperty, Value(0)));
    assert(e.horizontalAlignment == HorizontalAlignment.right, "and the refused write left it alone");

    e.clearValue(Element.horizontalAlignmentProperty);
    assert(e.horizontalAlignment == HorizontalAlignment.stretch);

    e.verticalAlignment = VerticalAlignment.bottom;
    assert(e.verticalAlignment == VerticalAlignment.bottom);
    assert(e.horizontalAlignment == HorizontalAlignment.stretch, "the two axes are separate properties");
}

unittest
{
    // A struct-typed property, also a first.  Note what decides whether it
    // changed: the property system compares the stored bytes, not Thickness's
    // own equality, so the same thickness assigned twice is not news.
    auto e = new Element;

    assert(e.margin == Thickness.init);
    assert(!e.hasLocalValue(Element.marginProperty));

    e.margin = Thickness(1, 2, 3, 4);
    assert(e.margin == Thickness(1, 2, 3, 4));
    assert(e.margin.horizontal == 4 && e.margin.vertical == 6);

    e.measure(Size(500, 400));
    e.arrange(Rect(0, 0, 500, 400));
    assert(e.isMeasureValid);

    e.margin = Thickness(1, 2, 3, 4);
    assert(e.isMeasureValid, "the same thickness is not a change");

    e.margin = Thickness(1, 2, 3, 5);
    assert(!e.isMeasureValid, "a different one is");

    e.clearValue(Element.marginProperty);
    assert(e.margin == Thickness.init);
}

unittest
{
    // Which pass each of the new properties asks for.  Sizing bounds change
    // how much room the element wants, so they reach the parent; alignment
    // only moves it inside room it already has, so it does not.
    auto parent = new Element;
    auto e = new Element;
    parent.addChild(e);

    void settle()
    {
        // The child is invalidated first because a clean parent stops at its
        // own early-out and never reaches down.
        e.invalidateMeasure();
        parent.measure(Size(500, 400));
        parent.arrange(Rect(0, 0, 500, 400));
        assert(parent.isMeasureValid && parent.isArrangeValid);
        assert(e.isMeasureValid && e.isArrangeValid);
    }

    settle();
    e.margin = Thickness(4);
    assert(!e.isMeasureValid && !parent.isMeasureValid, "a margin is part of what it costs");

    settle();
    e.minWidth = 30;
    assert(!e.isMeasureValid && !parent.isMeasureValid);

    settle();
    e.maxHeight = 300;
    assert(!e.isMeasureValid && !parent.isMeasureValid);

    settle();
    e.horizontalAlignment = HorizontalAlignment.left;
    assert(e.isMeasureValid, "where it sits does not change how big it is");
    assert(!e.isArrangeValid);
    assert(parent.isMeasureValid && parent.isArrangeValid, "and its parent does not move");

    settle();
    e.verticalAlignment = VerticalAlignment.top;
    assert(e.isMeasureValid && !e.isArrangeValid);
    assert(parent.isArrangeValid);
}

version (unittest)
{
   /*
    * Records the constraint it was measured against and answers with a size
    * fixed in advance, so a test can look at both halves of a measure.
    */
    private static class SizeProbe : Element
    {
        Size seenAvailable;
        Size answer;

        this(Size answer = Size(0, 0))
        {
            this.answer = answer;
        }

        protected override Size measureOverride(Size availableSize)
        {
            seenAvailable = availableSize;
            return answer;
        }
    }
}

unittest
{
    // The margin comes out of the room on offer and goes back onto the answer.
    auto p = new SizeProbe(Size(100, 50));
    p.margin = Thickness(10, 20, 30, 40);

    p.measure(Size(500, 400));

    assert(p.seenAvailable == Size(460, 340), "40 of width and 60 of height went to the margin");
    assert(p.unclippedDesiredSize == Size(100, 50), "what the content needed, margin excluded");
    assert(p.desiredSize == Size(140, 110), "what it costs the parent, margin included");
}

unittest
{
    // A margin wider than the room on offer leaves nothing rather than leaving
    // a negative amount, and the answer is still capped at what was offered.
    auto p = new SizeProbe(Size(0, 0));
    p.margin = Thickness(400);

    p.measure(Size(500, 400));

    assert(p.seenAvailable == Size(0, 0), "there is no such thing as minus sixty of width");
    assert(p.desiredSize == Size(500, 400), "and it wants all of what there was");
}

unittest
{
    // Bounds and an explicit width are one range, not rivals.
    auto p = new SizeProbe(Size(0, 0));

    // A minimum raises the question without raising what the parent is told.
    p.minWidth = 100;
    p.measure(Size(50, 400));
    assert(p.seenAvailable.width == 100);
    assert(p.unclippedDesiredSize.width == 100);
    assert(p.desiredSize.width == 50, "the offer still caps the answer");

    // A maximum lowers it.
    p.invalidateMeasure();
    p.minWidth = 0;
    p.maxWidth = 80;
    p.measure(Size(500, 400));
    assert(p.seenAvailable.width == 80);

    // A width of its own collapses the range onto itself.
    p.invalidateMeasure();
    p.maxWidth = 500;
    p.minWidth = 50;
    p.width = 200;
    p.measure(Size(1000, 400));
    assert(p.seenAvailable.width == 200);

    // A maximum pulls that width down.
    p.invalidateMeasure();
    p.width = 900;
    p.maxWidth = 400;
    p.measure(Size(1000, 400));
    assert(p.seenAvailable.width == 400);

    // And a minimum beats a maximum that contradicts it, rather than leaving a
    // range nothing can satisfy.
    p.invalidateMeasure();
    p.clearValue(Element.widthProperty);
    p.minWidth = 300;
    p.maxWidth = 100;
    p.measure(Size(1000, 400));
    assert(p.seenAvailable.width == 300);
}

unittest
{
    // Infinity is how a parent asks "how much would you like?".  It reaches
    // measureOverride only when nothing bounds the element, which is exactly
    // when the question means anything.
    auto p = new SizeProbe(Size(40, 25));

    p.measure(Size(float.infinity, 400));
    assert(p.seenAvailable.width == float.infinity);
    assert(p.desiredSize == Size(40, 25), "nothing infinite comes back out");

    p.invalidateMeasure();
    p.margin = Thickness(10);
    p.measure(Size(float.infinity, 400));
    assert(p.seenAvailable.width == float.infinity, "a finite margin does not dent it");

    p.invalidateMeasure();
    p.margin = Thickness.init;
    p.maxWidth = 120;
    p.measure(Size(float.infinity, 400));
    assert(p.seenAvailable.width == 120, "a maximum is what turns the offer back into a number");

    // And the early-out survives it, which it would not survive for NaN.
    auto c = new Counter;
    c.measure(Size(float.infinity, 400));
    c.measure(Size(float.infinity, 400));
    assert(c.measures == 1);
}

unittest
{
    // The margin insets the element inside the slot it was given, and what it
    // reports as its size is what is left after the inset.
    auto e = new Element;
    e.margin = Thickness(10, 20, 30, 40);

    e.measure(Size(500, 400));
    e.arrange(Rect(0, 0, 500, 400));

    assert(e.actualWidth == 460 && e.actualHeight == 340);
    assert(e.arrangedRect == Rect(10, 20, 460, 340), "in by the left and top margins");
}

version (unittest)
{
    private Element aligned(float w, float h, HorizontalAlignment ha, VerticalAlignment va)
    {
        auto e = new Element;
        e.width = w;
        e.height = h;
        e.horizontalAlignment = ha;
        e.verticalAlignment = va;
        return e;
    }

    private Rect place(Element e)
    {
        e.measure(Size(200, 100));
        e.arrange(Rect(0, 0, 200, 100));
        return e.arrangedRect;
    }
}

unittest
{
    // Where each alignment puts an element that is smaller than its room.
    assert(place(aligned(50, 20, HorizontalAlignment.left, VerticalAlignment.top))
           == Rect(0, 0, 50, 20));
    assert(place(aligned(50, 20, HorizontalAlignment.center, VerticalAlignment.center))
           == Rect(75, 40, 50, 20));
    assert(place(aligned(50, 20, HorizontalAlignment.right, VerticalAlignment.bottom))
           == Rect(150, 80, 50, 20));

    // The axes are independent.
    assert(place(aligned(50, 20, HorizontalAlignment.right, VerticalAlignment.top))
           == Rect(150, 0, 50, 20));

    // Stretch with nothing to insist on takes the whole slot.
    auto bare = new Element;
    assert(place(bare) == Rect(0, 0, 200, 100));

    // And stretch with a size of its own cannot stretch, so it centres.  This
    // is the one a reader does not predict: a width of its own beats stretch,
    // and what stretch does when it cannot stretch is put the element in the
    // middle rather than in a corner.
    assert(place(aligned(50, 20, HorizontalAlignment.stretch, VerticalAlignment.stretch))
           == Rect(75, 40, 50, 20));
}

unittest
{
    // An element too big for its slot overflows it rather than being squeezed
    // into it, and starts at the near corner so that what is cut off is the
    // far side rather than both.
    auto e = new Element;
    e.width = 300;
    e.height = 200;

    e.measure(Size(100, 50));
    assert(e.desiredSize == Size(100, 50), "the parent hears what it offered");
    assert(e.unclippedDesiredSize == Size(300, 200), "arrange hears what was wanted");

    e.arrange(Rect(0, 0, 100, 50));
    assert(e.actualWidth == 300 && e.actualHeight == 200,
           "arranged at what it needed, not at what fitted");
    assert(e.arrangedRect == Rect(0, 0, 300, 200));
}

unittest
{
    // Re-arranging goes back to the slot, not to the placement.  Alignment
    // carries affectsArrange, so re-arranging is exactly what changing one
    // causes -- and passing the placement would walk a right-aligned element
    // across its slot, one pass at a time, until it left the tree.
    auto e = aligned(50, 20, HorizontalAlignment.right, VerticalAlignment.bottom);

    e.measure(Size(200, 100));
    e.arrange(Rect(0, 0, 200, 100));
    assert(e.arrangedRect == Rect(150, 80, 50, 20));

    foreach (_; 0 .. 3)
    {
        e.invalidateArrange();
        e.arrangeAsRoot();
        assert(e.arrangedRect == Rect(150, 80, 50, 20), "the same slot, so the same place");
    }
}

unittest
{
    // And the early-out compares the slot too: an element offered the same
    // slot twice is not arranged twice, however far from that slot's corner
    // its alignment put it.
    auto c = new Counter;
    c.horizontalAlignment = HorizontalAlignment.right;

    c.arrange(Rect(0, 0, 200, 100));
    assert(c.arranges == 1);
    assert(c.arrangedRect.x == 200, "nowhere near the slot's corner");

    c.arrange(Rect(0, 0, 200, 100));
    assert(c.arranges == 1);
}

version (unittest)
{
    import cherry.platform.render : Color, FakeSolidPaint, Point, RecordingContext;

   /*
    * Draws its own bounds, which in its own space start at the origin.  What
    * a test then reads back from the recorder is where those bounds landed.
    */
    private static class Marker : Element
    {
        protected override void onRender(DrawingContext context)
        {
            context.fillRectangle(Rect(0, 0, actualWidth, actualHeight), new FakeSolidPaint(Color.black));
        }
    }
}

unittest
{
    // An element draws at its own origin, and the walk puts it where it
    // belongs.  Two levels of margin, so the spaces nest.
    auto root = new Marker;
    auto a = new Marker;
    auto g = new Marker;
    root.addChild(a);
    a.addChild(g);

    a.margin = Thickness(10);
    g.margin = Thickness(5);

    root.measure(Size(200, 100));
    root.arrange(Rect(0, 0, 200, 100));

    auto ctx = new RecordingContext;
    root.renderSubtree(ctx);

    assert(ctx.entries.length == 3);
    assert(ctx.entries[0].rect == Rect(0, 0, 200, 100));
    assert(ctx.entries[1].rect == Rect(10, 10, 180, 80));
    assert(ctx.entries[2].rect == Rect(15, 15, 170, 70));
    assert(ctx.depth == 0, "and the walk left the stack as it found it");
}

unittest
{
    // The test that earns its place: the only one at tree level that can fail
    // when the composition order is reversed.
    //
    // renderSubtree pushes translations and nothing else, and translations
    // commute -- so a whole tree of nested elements gives the same answer
    // whichever way round the composition goes.  Only something that is not a
    // translation tells them apart, and this pushes a scale from inside an
    // element that has already been moved.
    static class Scaler : Element
    {
        protected override void onRender(DrawingContext context)
        {
            context.pushTransform(Matrix.scaling(2, 2));
            context.fillRectangle(Rect(10, 10, 20, 20), new FakeSolidPaint(Color.black));
            context.popTransform();
        }
    }

    auto root = new Element;
    auto scaler = new Scaler;
    root.addChild(scaler);

    scaler.width = 50;
    scaler.height = 20;
    scaler.margin = Thickness(100, 50, 0, 0);
    scaler.horizontalAlignment = HorizontalAlignment.left;
    scaler.verticalAlignment = VerticalAlignment.top;

    root.measure(Size(400, 300));
    root.arrange(Rect(0, 0, 400, 300));
    assert(scaler.arrangedRect == Rect(100, 50, 50, 20));

    auto ctx = new RecordingContext;
    root.renderSubtree(ctx);

    // Scale first, then the element's own placement: (10,10) doubles to
    // (20,20) and then moves by (100,50).  Composed the other way it would be
    // (10+100, 10+50) doubled, which is (220, 120) -- not subtly wrong.
    assert(ctx.entries[$ - 1].rect == Rect(120, 70, 40, 40));
}

unittest
{
    // A margin and an alignment move a child, and its drawing code does not
    // notice.  Both halves matter: the first is that the placement is
    // honoured, the second is the promise of the whole design.
    auto parent = new Element;
    auto child = new Marker;
    parent.addChild(child);

    child.width = 50;
    child.height = 20;
    child.margin = Thickness(5);
    child.horizontalAlignment = HorizontalAlignment.right;
    child.verticalAlignment = VerticalAlignment.bottom;

    parent.measure(Size(200, 100));
    parent.arrange(Rect(0, 0, 200, 100));
    assert(child.arrangedRect == Rect(145, 75, 50, 20));

    auto ctx = new RecordingContext;
    child.renderSubtree(ctx);
    assert(ctx.entries[0].rect == Rect(145, 75, 50, 20), "where the parent put it");

    // And what it asked to draw, in its own space, was the origin.
    assert(ctx.entries[0].transform.transform(Point(0, 0)) == Point(145, 75));
    assert(child.actualWidth == 50 && child.actualHeight == 20,
           "its own bounds are Rect(0, 0, 50, 20) and it never said otherwise");
}

unittest
{
    // The root is not a special case -- it pushes its own placement too,
    // which is why a Window needs no exception rather than being one.
    auto e = new Marker;
    e.arrange(Rect(10, 20, 300, 150));

    auto ctx = new RecordingContext;
    e.renderSubtree(ctx);

    assert(ctx.entries[0].rect == Rect(10, 20, 300, 150));
}

unittest
{
    // What an element sees when it asks where it is.
    static class Asker : Element
    {
        Point origin;

        protected override void onRender(DrawingContext context)
        {
            origin = context.currentTransform.transform(Point(0, 0));
        }
    }

    auto root = new Element;
    auto asker = new Asker;
    root.addChild(asker);

    asker.width = 40;
    asker.height = 30;
    asker.horizontalAlignment = HorizontalAlignment.right;
    asker.verticalAlignment = VerticalAlignment.bottom;

    root.measure(Size(200, 100));
    root.arrange(Rect(0, 0, 200, 100));

    root.renderSubtree(new RecordingContext);
    assert(asker.origin == Point(160, 70), "the current transform maps my space to the window's");
}

unittest
{
    // An exception on its way out of an element unwinds every push it passes,
    // so whoever called renderSubtree finds the context as they left it.
    import std.exception : assertThrown;

    static class Thrower : Element
    {
        protected override void onRender(DrawingContext context)
        {
            throw new Exception("boom");
        }
    }

    auto root = new Element;
    auto middle = new Element;
    auto thrower = new Thrower;
    root.addChild(middle);
    middle.addChild(thrower);

    root.measure(Size(200, 100));
    root.arrange(Rect(0, 0, 200, 100));

    auto ctx = new RecordingContext;
    assertThrown(root.renderSubtree(ctx));
    assert(ctx.depth == 0, "three pushes, three pops, one exception");

    // The positive control: a walk that returns normally ends level too.
    auto plain = new RecordingContext;
    new Element().renderSubtree(plain);
    assert(plain.depth == 0);
}

unittest
{
    // renderBounds is the element's own box, in its own space.
    auto e = new Element;
    assert(e.renderBounds == Rect(0, 0, 0, 0), "nothing until it has been arranged");

    e.arrange(Rect(10, 20, 300, 150));
    assert(e.renderBounds == Rect(0, 0, 300, 150), "its size, at its own origin");
}

unittest
{
    // toRootSpace agrees with what the render walk actually does.
    //
    // Asserted against the recorder's own output rather than against numbers
    // written out here, so that the two cannot drift apart: this is the same
    // tree as the nesting test above, and the point is that the offset the
    // walk accumulates and the offset this computes are the same offset.
    auto root = new Marker;
    auto a = new Marker;
    auto g = new Marker;
    root.addChild(a);
    a.addChild(g);

    a.margin = Thickness(10);
    g.margin = Thickness(5);

    root.measure(Size(200, 100));
    root.arrange(Rect(0, 0, 200, 100));

    auto ctx = new RecordingContext;
    root.renderSubtree(ctx);

    assert(root.toRootSpace(root.renderBounds) == ctx.entries[0].rect);
    assert(a.toRootSpace(a.renderBounds) == ctx.entries[1].rect);
    assert(g.toRootSpace(g.renderBounds) == ctx.entries[2].rect);
}

unittest
{
    // A detached element is the top of its own fragment, so the walk covers
    // only its own placement.
    auto orphan = new Element;
    orphan.arrange(Rect(7, 9, 40, 30));

    assert(orphan.root is orphan);
    assert(orphan.toRootSpace(Rect(1, 2, 5, 5)) == Rect(8, 11, 5, 5));
}

unittest
{
    // A property that says it affects rendering gets a repaint asked for, and
    // nothing else: it is not a size and it is not a place.
    //
    // No property in the framework carries this flag today, and that is the
    // answer rather than an oversight -- everything visible that the sizing
    // and alignment properties change moves the element, and arranging asks
    // for the repaint itself under a check the flag would not have.  The flag
    // is wired for the first property that genuinely needs it: a Background,
    // a Foreground, an Opacity, the day brushes exist.
    static class Painted : Element
    {
        shared static this()
        {
            PropertyMetadata renderMeta;
            renderMeta.defaultValue = Value(0);
            renderMeta.affectsRender = true;

            shadeProperty = Property.register("Shade", getRtti!int(), getRtti!Painted(), renderMeta);
        }

        static immutable(Property) shadeProperty;
    }

    auto parent = new Element;
    auto e = new Painted;
    parent.addChild(e);

    parent.measure(Size(500, 400));
    parent.arrange(Rect(0, 0, 500, 400));
    e.invalidateVisual();
    parent.updateLayout();
    assert(e.isMeasureValid && e.isArrangeValid && e.isVisualValid);

    e.setValue(Painted.shadeProperty, Value(1));

    assert(!e.isVisualValid, "it said it would look different, and it is taken at its word");
    assert(e.isMeasureValid, "but it is the same size");
    assert(e.isArrangeValid, "and in the same place");
    assert(parent.isVisualValid, "and its parent did not change at all");
}
