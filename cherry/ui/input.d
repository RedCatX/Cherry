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

/**
 * The element that was holding the pointer is no longer holding it.
 *
 * Direct, because it concerns exactly one element -- the one that asked.  It
 * arrives however the capture ended: given up, taken by another element, or
 * taken by the system, which happens for reasons no application can see.  An
 * element that undoes its pressed state on the button release alone will be
 * left pressed after the first task switch.
 */
immutable RoutedEvent mouseCaptureLostEvent;

shared static this()
{
    mouseDownEvent  = RoutedEvent.register("MouseDown", RoutingStrategy.bubble, getRtti!Element());
    mouseUpEvent    = RoutedEvent.register("MouseUp", RoutingStrategy.bubble, getRtti!Element());
    mouseMoveEvent  = RoutedEvent.register("MouseMove", RoutingStrategy.bubble, getRtti!Element());
    mouseEnterEvent = RoutedEvent.register("MouseEnter", RoutingStrategy.direct, getRtti!Element());
    mouseLeaveEvent = RoutedEvent.register("MouseLeave", RoutingStrategy.direct, getRtti!Element());
    mouseCaptureLostEvent = RoutedEvent.register("MouseCaptureLost",
        RoutingStrategy.direct, getRtti!Element());
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

/// ditto
@property auto onMouseCaptureLost(Element element)
{
    return routedAccessor(element, mouseCaptureLostEvent);
}

package:

/**
 * Moves the pointer from one element to another, telling everything the change
 * really affects and nothing else.
 *
 * Both arguments are the deepest element under the pointer, before and after;
 * either may be null, which is how the pointer entering the window for the
 * first time and leaving it altogether are expressed.
 *
 * The chains from each up to the root share a tail -- the elements the pointer
 * was inside before and still is.  Those hear nothing: it never left them, and
 * telling them otherwise is exactly the bug that makes hover flicker when the
 * pointer crosses a boundary between two children of the same parent.  Only the
 * parts below the deepest shared element change.
 *
 * Order matters in both directions.  Leaving runs from the deepest outwards, so
 * an element is told after everything inside it already has been; entering runs
 * from the outermost inwards, so a container knows the pointer is in it before
 * the child it landed on says the same.  A handler on either can then trust that
 * the elements around it are already in the state it is reading.
 *
 * Lives here rather than in Window because it is about the element tree, and
 * window.d imports this module while nothing imports window.d back.
 */
void updateMouseOver(Element previous, Element current, float x, float y)
{
    if (previous is current)
        return;

    auto leaving = chainToRoot(previous);
    auto entering = chainToRoot(current);

    // The deepest element on both chains: where the pointer has been all along.
    Element common;

    search: foreach (candidate; leaving)
        foreach (other; entering)
            if (other is candidate)
            {
                common = candidate;
                break search;
            }

    foreach (element; leaving)
    {
        if (element is common)
            break;

        element.setMouseOver(false);
        element.raiseEvent(new MouseEventArgs(mouseLeaveEvent, MouseButton.none, x, y));
    }

    // How much of the entering chain is new, so it can be walked backwards --
    // outermost first.
    size_t fresh;
    foreach (element; entering)
    {
        if (element is common)
            break;

        ++fresh;
    }

    foreach_reverse (i; 0 .. fresh)
    {
        entering[i].setMouseOver(true);
        entering[i].raiseEvent(new MouseEventArgs(mouseEnterEvent, MouseButton.none, x, y));
    }
}

/*
 * An element and every ancestor above it, deepest first.  Empty for null,
 * which is what makes "the pointer is nowhere" an ordinary case rather than a
 * branch at every use.
 */
private Element[] chainToRoot(Element leaf)
{
    Element[] chain;

    for (Element e = leaf; e !is null; e = e.parent)
        chain ~= e;

    return chain;
}

public:

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
