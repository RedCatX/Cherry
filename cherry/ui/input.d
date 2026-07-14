module cherry.ui.input;

import cherry.core.rtti;
import cherry.ui.element;
import cherry.ui.event;

public import cherry.platform.window : MouseButton;

/**
 * Arguments of the mouse routed events: which button, and where in the
 * client area of the top-level window the event happened.
 */
class MouseEventArgs : RoutedEventArgs
{
    this(immutable(RoutedEvent) routedEvent, MouseButton button, int x, int y)
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

    @property int x() pure const nothrow
    {
        return _x;
    }

    @property int y() pure const nothrow
    {
        return _y;
    }

private:
    MouseButton _button;
    int _x;
    int _y;
}

/**
 * The mouse routed events, registered for every Element.  Until layout and
 * hit-testing exist, the platform input is raised on the top-level Window
 * element; once elements have bounds, the deepest hit element becomes the
 * route target instead.
 */
immutable RoutedEvent mouseDownEvent;
/// ditto
immutable RoutedEvent mouseUpEvent;
/// ditto
immutable RoutedEvent mouseMoveEvent;

shared static this()
{
    mouseDownEvent = RoutedEvent.register("MouseDown", RoutingStrategy.bubble, getRtti!Element());
    mouseUpEvent   = RoutedEvent.register("MouseUp", RoutingStrategy.bubble, getRtti!Element());
    mouseMoveEvent = RoutedEvent.register("MouseMove", RoutingStrategy.bubble, getRtti!Element());
}

/**
 * Subscription accessors for the mouse events, usable on any element via
 * UFCS: `window.onMouseDown ~= &handler;`.
 */
@property EventAccessor onMouseDown(Element element)
{
    return EventAccessor(element, mouseDownEvent);
}

/// ditto
@property EventAccessor onMouseUp(Element element)
{
    return EventAccessor(element, mouseUpEvent);
}

/// ditto
@property EventAccessor onMouseMove(Element element)
{
    return EventAccessor(element, mouseMoveEvent);
}

unittest
{
    // The events are registered once, distinctly, for Element.
    assert(mouseDownEvent !is null && mouseUpEvent !is null && mouseMoveEvent !is null);
    assert(mouseDownEvent.id != mouseUpEvent.id && mouseUpEvent.id != mouseMoveEvent.id);
    assert(mouseDownEvent.routingStrategy == RoutingStrategy.bubble);
    assert(mouseDownEvent.ownerType is getRtti!Element());
}
