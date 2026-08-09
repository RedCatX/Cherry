module cherry.ui.input;

import cherry.core.rtti;
import cherry.platform.render : Point;
import cherry.ui.element;
import cherry.ui.event;
import cherry.ui.visual : Visual;

public import cherry.platform.window : MouseButton;

/**
 * Arguments of the mouse routed events: which button, and where in the
 * client area of the top-level window the event happened.
 */
class MouseEventArgs : RoutedEventArgs
{
    this(immutable(RoutedEvent) routedEvent, MouseButton button, float x, float y)
    {
        super(routedEvent);
        _button = button;
        _x = x;
        _y = y;
    }

    @property MouseButton button() pure const nothrow
    {
        return _button;
    }

   /**
    * Where it happened, in the client area of the top-level window.
    *
    * Float, like every other coordinate in the framework.  The platform counts
    * in whole pixels and says so in ints; that is the platform's truth and it
    * is converted once, at the boundary, rather than being carried up through
    * an API whose units are device-independent.
    *
    * A handler somewhere down the tree usually wants this in its own terms
    * instead -- that is what getPosition is for.
    */
    @property float x() pure const nothrow
    {
        return _x;
    }

    /// ditto
    @property float y() pure const nothrow
    {
        return _y;
    }

   /**
    * Where it happened, in the coordinate space of the visual given.
    *
    * The point of a routed event is that a handler does not have to know where
    * its element sits; this is what keeps that true of the position as well.
    * `args.getPosition(this)` inside a handler is the local point, whatever the
    * layout did with the element since.
    *
    * Passing the window gives back the client-area point, because a window's
    * own space is the client area.
    */
    Point getPosition(Visual relativeTo)
    in {
        assert(relativeTo !is null);
    }
    do {
        return relativeTo.fromRootSpace(Point(_x, _y));
    }

private:
    MouseButton _button;
    float _x;
    float _y;
}

/**
 * The mouse routed events, registered for every Element.  The window
 * hit-tests each native notification and raises these on the deepest element
 * under the pointer, so they travel up from there.
 */
immutable RoutedEvent mouseDownEvent;
/// ditto
immutable RoutedEvent mouseUpEvent;
/// ditto
immutable RoutedEvent mouseMoveEvent;

/**
 * The pointer arrived over an element, or left it.
 *
 * **Direct, not bubbling**, which is WPF's choice and worth understanding:
 * the pointer moving from one child to another has not left their common
 * parent, so an event travelling up would tell that parent it was left and
 * entered again on every move across a boundary inside it.  The chain is built
 * the other way instead -- the window works out which elements the change
 * really affects and raises the event on each of them separately.
 */
immutable RoutedEvent mouseEnterEvent;
/// ditto
immutable RoutedEvent mouseLeaveEvent;

shared static this()
{
    mouseDownEvent  = RoutedEvent.register("MouseDown", RoutingStrategy.bubble, getRtti!Element());
    mouseUpEvent    = RoutedEvent.register("MouseUp", RoutingStrategy.bubble, getRtti!Element());
    mouseMoveEvent  = RoutedEvent.register("MouseMove", RoutingStrategy.bubble, getRtti!Element());
    mouseEnterEvent = RoutedEvent.register("MouseEnter", RoutingStrategy.direct, getRtti!Element());
    mouseLeaveEvent = RoutedEvent.register("MouseLeave", RoutingStrategy.direct, getRtti!Element());
}

/**
 * Subscription accessors for the mouse events, usable on any element via
 * UFCS: `window.onMouseDown ~= &handler;`.
 */
@property auto onMouseDown(Element element)
{
    return routedAccessor(element, mouseDownEvent);
}

/// ditto
@property auto onMouseUp(Element element)
{
    return routedAccessor(element, mouseUpEvent);
}

/// ditto
@property auto onMouseMove(Element element)
{
    return routedAccessor(element, mouseMoveEvent);
}

/// ditto
@property auto onMouseEnter(Element element)
{
    return routedAccessor(element, mouseEnterEvent);
}

/// ditto
@property auto onMouseLeave(Element element)
{
    return routedAccessor(element, mouseLeaveEvent);
}

unittest
{
    // The events are registered once, distinctly, for Element.
    assert(mouseDownEvent !is null && mouseUpEvent !is null && mouseMoveEvent !is null);
    assert(mouseDownEvent.id != mouseUpEvent.id && mouseUpEvent.id != mouseMoveEvent.id);
    assert(mouseDownEvent.routingStrategy == RoutingStrategy.bubble);
    assert(mouseDownEvent.ownerType is getRtti!Element());

    // Enter and leave do not travel, and the whole design of the chain rests
    // on that: raising them on each affected element is what a bubbling
    // version would get wrong.
    assert(mouseEnterEvent.routingStrategy == RoutingStrategy.direct);
    assert(mouseLeaveEvent.routingStrategy == RoutingStrategy.direct);
    assert(mouseEnterEvent.id != mouseLeaveEvent.id);
}

unittest
{
    // Nobody is under the pointer until somebody says so, and only this
    // package can say it.
    auto element = new Element;

    assert(!element.isMouseOver);
    assert(Element.isMouseOverProperty.isReadOnly, "user code reports on the pointer, never moves it");

    element.setMouseOver(true);
    assert(element.isMouseOver);

    element.setMouseOver(false);
    assert(!element.isMouseOver);
}

unittest
{
    // The same event read in three coordinate spaces.
    import cherry.platform.render : Rect, Size, Thickness;

    auto root = new Element;
    auto middle = new Element;
    auto leaf = new Element;
    root.addChild(middle);
    middle.addChild(leaf);

    middle.margin = Thickness(30, 20, 0, 0);
    leaf.margin = Thickness(5);

    root.measure(Size(200, 100));
    root.arrange(Rect(0, 0, 200, 100));

    auto args = new MouseEventArgs(mouseDownEvent, MouseButton.left, 50, 40);

    assert(args.x == 50 && args.y == 40, "the client point, as it arrived");
    assert(args.getPosition(root) == Point(50, 40), "the root's space is the client area");
    assert(args.getPosition(middle) == Point(20, 20), "in by the margin above it");
    assert(args.getPosition(leaf) == Point(15, 15), "and by its own on top of that");
}
