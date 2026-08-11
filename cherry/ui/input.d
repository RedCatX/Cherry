module cherry.ui.input;

import cherry.core.rtti;
import cherry.platform.render : Point;
import cherry.ui.element;
import cherry.ui.event;
import cherry.ui.visual : Visual;

public import cherry.platform.window : Key, ModifierKeys, MouseButton;

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
 * Arguments of the key events: which key, what was held down with it, and
 * whether the auto-repeat produced it rather than the user.
 *
 * The key names a **position**, not a character -- see Key.  Something acting
 * on what was typed wants TextInputEventArgs instead, and the two are not
 * interchangeable in either direction.
 */
class KeyEventArgs : RoutedEventArgs
{
    this(immutable(RoutedEvent) routedEvent, Key key, ModifierKeys modifiers,
         bool isRepeat = false)
    {
        super(routedEvent);
        _key = key;
        _modifiers = modifiers;
        _isRepeat = isRepeat;
    }

    @property Key key() pure const nothrow
    {
        return _key;
    }

   /**
    * Which modifiers were held.  A bit field: test with `&`, because
    * Ctrl+Shift+S is not something other than Ctrl+S with a bit to spare.
    */
    @property ModifierKeys modifiers() pure const nothrow
    {
        return _modifiers;
    }

   /**
    * Whether the key was already down and the auto-repeat sent this.
    *
    * The thing a control has to decide for itself: holding Space on a button
    * should press it once, holding it in a text field should type many spaces.
    */
    @property bool isRepeat() pure const nothrow
    {
        return _isRepeat;
    }

private:
    Key         _key;
    ModifierKeys _modifiers;
    bool        _isRepeat;
}

/**
 * Arguments of the text event: what was typed.
 *
 * A string and not a character, because one keystroke is not one character and
 * one character is not one keystroke: an input method can deliver a word at a
 * time, and a character outside the basic plane arrives from the platform in
 * pieces that are joined before this is raised.
 */
class TextInputEventArgs : RoutedEventArgs
{
    this(immutable(RoutedEvent) routedEvent, string text)
    {
        super(routedEvent);
        _text = text;
    }

    @property string text() pure const nothrow
    {
        return _text;
    }

private:
    string _text;
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

/**
 * A key went down or came back up, and what was typed.
 *
 * Bubbling, and raised on the **focused** element -- the keyboard's answer to
 * the question hit-testing answers for the mouse.  With nothing focused they
 * start at the window, so a shortcut handler placed there hears everything
 * whether or not anything inside has the keyboard.
 *
 * There are no preview (tunnelling) counterparts.  What they exist for in WPF
 * is letting the framework act before a control does, and the class-handler
 * tier already gives that -- see registerClassHandler in event.d.  They arrive
 * the day something genuinely needs to intercept an event on its way down.
 */
immutable RoutedEvent keyDownEvent;
/// ditto
immutable RoutedEvent keyUpEvent;
/// ditto
immutable RoutedEvent textInputEvent;

/**
 * The keyboard arrived at an element, or left it.
 *
 * **Bubbling**, which is WPF's choice and the opposite of the enter/leave pair
 * next to it.  The difference is what the two are about: the pointer is inside
 * everything that contains where it is, so telling a common ancestor it was
 * left and entered again would be false, whereas the keyboard is at exactly one
 * element and an ancestor hearing about it is hearing something true --
 * "something inside me now has the keyboard", which is what a container wants
 * in order to light up.
 */
immutable RoutedEvent gotFocusEvent;
/// ditto
immutable RoutedEvent lostFocusEvent;

shared static this()
{
    mouseDownEvent  = RoutedEvent.register("onMouseDown", RoutingStrategy.bubble, getRtti!Element());
    mouseUpEvent    = RoutedEvent.register("onMouseUp", RoutingStrategy.bubble, getRtti!Element());
    mouseMoveEvent  = RoutedEvent.register("onMouseMove", RoutingStrategy.bubble, getRtti!Element());
    mouseEnterEvent = RoutedEvent.register("onMouseEnter", RoutingStrategy.direct, getRtti!Element());
    mouseLeaveEvent = RoutedEvent.register("onMouseLeave", RoutingStrategy.direct, getRtti!Element());
    mouseCaptureLostEvent = RoutedEvent.register("onMouseCaptureLost",
        RoutingStrategy.direct, getRtti!Element());

    keyDownEvent    = RoutedEvent.register("onKeyDown", RoutingStrategy.bubble, getRtti!Element());
    keyUpEvent      = RoutedEvent.register("onKeyUp", RoutingStrategy.bubble, getRtti!Element());
    textInputEvent  = RoutedEvent.register("onTextInput", RoutingStrategy.bubble, getRtti!Element());
    gotFocusEvent   = RoutedEvent.register("onGotFocus", RoutingStrategy.bubble, getRtti!Element());
    lostFocusEvent  = RoutedEvent.register("onLostFocus", RoutingStrategy.bubble, getRtti!Element());

    // And the tier that lets an element act on the mouse because of what it is:
    // one class handler apiece, each calling the matching hook on Element, so
    // that a control overrides a method instead of subscribing to itself.
    //
    // Registered here rather than in element.d because that is where the events
    // are, and registered for Element rather than by each control because the
    // hook is Element's -- what a control does is override it.
    mouseDownEvent.registerClassHandler(getRtti!Element(), &Element.callHandleMouseDown);
    mouseUpEvent.registerClassHandler(getRtti!Element(), &Element.callHandleMouseUp);
    mouseMoveEvent.registerClassHandler(getRtti!Element(), &Element.callHandleMouseMove);
    mouseEnterEvent.registerClassHandler(getRtti!Element(), &Element.callHandleMouseEnter);
    mouseLeaveEvent.registerClassHandler(getRtti!Element(), &Element.callHandleMouseLeave);
    mouseCaptureLostEvent.registerClassHandler(getRtti!Element(),
        &Element.callHandleMouseCaptureLost);

    keyDownEvent.registerClassHandler(getRtti!Element(), &Element.callHandleKeyDown);
    keyUpEvent.registerClassHandler(getRtti!Element(), &Element.callHandleKeyUp);
    textInputEvent.registerClassHandler(getRtti!Element(), &Element.callHandleTextInput);
    gotFocusEvent.registerClassHandler(getRtti!Element(), &Element.callHandleGotFocus);
    lostFocusEvent.registerClassHandler(getRtti!Element(), &Element.callHandleLostFocus);
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

/// ditto
@property auto onKeyDown(Element element)
{
    return routedAccessor(element, keyDownEvent);
}

/// ditto
@property auto onKeyUp(Element element)
{
    return routedAccessor(element, keyUpEvent);
}

/// ditto
@property auto onTextInput(Element element)
{
    return routedAccessor(element, textInputEvent);
}

/// ditto
@property auto onGotFocus(Element element)
{
    return routedAccessor(element, gotFocusEvent);
}

/// ditto
@property auto onLostFocus(Element element)
{
    return routedAccessor(element, lostFocusEvent);
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
    // Every mouse event reaches the hook of the same name, ahead of anything
    // subscribed to the element -- and the hook is handed the very args the
    // subscribers get, so a control reads the position from the same object.
    static class Probe : Element
    {
        string[] seen;
        RoutedEventArgs last;

        protected override void handleMouseDown(RoutedEventArgs args)
        {
            super.handleMouseDown(args);
            seen ~= "down";
            last = args;
        }

        protected override void handleMouseUp(RoutedEventArgs args)
        {
            super.handleMouseUp(args);
            seen ~= "up";
        }

        protected override void handleMouseMove(RoutedEventArgs args)
        {
            super.handleMouseMove(args);
            seen ~= "move";
        }

        protected override void handleMouseEnter(RoutedEventArgs args)
        {
            super.handleMouseEnter(args);
            seen ~= "enter";
        }

        protected override void handleMouseLeave(RoutedEventArgs args)
        {
            super.handleMouseLeave(args);
            seen ~= "leave";
        }

        protected override void handleMouseCaptureLost(RoutedEventArgs args)
        {
            super.handleMouseCaptureLost(args);
            seen ~= "capture-lost";
        }
    }

    auto probe = new Probe;
    probe.onMouseDown ~= (Element sender, RoutedEventArgs args) {
        (cast(Probe) sender).seen ~= "subscriber";
    };

    auto down = new MouseEventArgs(mouseDownEvent, MouseButton.left, 7, 9);
    probe.raiseEvent(down);

    assert(probe.seen == ["down", "subscriber"], "the hook first, then the queue");
    assert(probe.last is down, "and on the same args, so the position is the same one");

    probe.seen = null;
    probe.raiseEvent(new MouseEventArgs(mouseUpEvent, MouseButton.left, 7, 9));
    probe.raiseEvent(new MouseEventArgs(mouseMoveEvent, MouseButton.none, 7, 9));
    probe.raiseEvent(new MouseEventArgs(mouseEnterEvent, MouseButton.none, 7, 9));
    probe.raiseEvent(new MouseEventArgs(mouseLeaveEvent, MouseButton.none, 7, 9));
    probe.raiseEvent(new RoutedEventArgs(mouseCaptureLostEvent));

    assert(probe.seen == ["up", "move", "enter", "leave", "capture-lost"],
           "all six wired, each to its own");
}

unittest
{
    // The keyboard events are registered once, distinctly, for Element.
    assert(keyDownEvent.routingStrategy == RoutingStrategy.bubble);
    assert(keyUpEvent.routingStrategy == RoutingStrategy.bubble);
    assert(textInputEvent.routingStrategy == RoutingStrategy.bubble);
    assert(keyDownEvent.id != keyUpEvent.id && keyUpEvent.id != textInputEvent.id);

    // Focus bubbles, unlike enter and leave beside it -- "something inside me
    // has the keyboard" is a true thing to tell an ancestor, where "the pointer
    // left me" would not have been.
    assert(gotFocusEvent.routingStrategy == RoutingStrategy.bubble);
    assert(lostFocusEvent.routingStrategy == RoutingStrategy.bubble);
    assert(gotFocusEvent.ownerType is getRtti!Element());
}

unittest
{
    // A key event says which key, what was held, and whether the user or the
    // auto-repeat produced it.
    auto plain = new KeyEventArgs(keyDownEvent, Key.space, ModifierKeys.none);

    assert(plain.key == Key.space);
    assert(plain.modifiers == ModifierKeys.none);
    assert(!plain.isRepeat, "a press until something says otherwise");

    immutable held = cast(ModifierKeys)(ModifierKeys.control | ModifierKeys.shift);
    auto combo = new KeyEventArgs(keyDownEvent, Key.s, held, true);

    assert(combo.isRepeat);
    assert((combo.modifiers & ModifierKeys.control) != 0);
    assert((combo.modifiers & ModifierKeys.shift) != 0);
    assert((combo.modifiers & ModifierKeys.alt) == 0);
    assert(combo.modifiers != ModifierKeys.control,
           "and testing a bit field for equality is how a shortcut goes wrong");

    // What was typed is a different question with a different answer.
    auto typed = new TextInputEventArgs(textInputEvent, "é");
    assert(typed.text == "é");
}

unittest
{
    // The five keyboard hooks are wired, each to its own event, and each ahead
    // of anything subscribed to the element.
    static class Typist : Element
    {
        string[] seen;

        protected override void handleKeyDown(RoutedEventArgs args)
        {
            super.handleKeyDown(args);

            auto pressed = cast(KeyEventArgs) args;
            seen ~= pressed.key == Key.a ? "down:a" : "down:?";
        }

        protected override void handleKeyUp(RoutedEventArgs args)
        {
            super.handleKeyUp(args);
            seen ~= "up";
        }

        protected override void handleTextInput(RoutedEventArgs args)
        {
            super.handleTextInput(args);
            seen ~= "text:" ~ (cast(TextInputEventArgs) args).text;
        }

        protected override void handleGotFocus(RoutedEventArgs args)
        {
            super.handleGotFocus(args);
            seen ~= "got";
        }

        protected override void handleLostFocus(RoutedEventArgs args)
        {
            super.handleLostFocus(args);
            seen ~= "lost";
        }
    }

    auto typist = new Typist;
    typist.onKeyDown ~= (Element sender, RoutedEventArgs args) {
        (cast(Typist) sender).seen ~= "subscriber";
    };

    typist.raiseEvent(new KeyEventArgs(keyDownEvent, Key.a, ModifierKeys.none));
    typist.raiseEvent(new KeyEventArgs(keyUpEvent, Key.a, ModifierKeys.none));
    typist.raiseEvent(new TextInputEventArgs(textInputEvent, "a"));
    typist.raiseEvent(new RoutedEventArgs(gotFocusEvent));
    typist.raiseEvent(new RoutedEventArgs(lostFocusEvent));

    assert(typist.seen == ["down:a", "subscriber", "up", "text:a", "got", "lost"],
           "each hook on its own event, and the hook before the queue");
}

unittest
{
    // Focus bubbles: a container hears that something inside it has the
    // keyboard, with args.source naming which.
    auto panel = new Element;
    auto field = new Element;
    panel.addChild(field);

    Element heard;
    panel.onGotFocus ~= (Element sender, RoutedEventArgs args) { heard = args.source; };

    field.raiseEvent(new RoutedEventArgs(gotFocusEvent));
    assert(heard is field);
}

unittest
{
    // An element that overrides nothing is unaffected: the hooks are empty and
    // the events reach its subscribers exactly as they did before the tier.
    auto plain = new Element;

    int heard;
    plain.onMouseDown ~= (Element sender, RoutedEventArgs args) { ++heard; };

    plain.raiseEvent(new MouseEventArgs(mouseDownEvent, MouseButton.left, 1, 2));
    assert(heard == 1);
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
