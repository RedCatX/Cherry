module cherry.ui.controls.button;

/*
 * A module constructor here is safe for the reason stackpanel.d's banner spells
 * out: the imports of this package run one way.
 */

import cherry.core.multicast : event;
import cherry.core.property;
import cherry.core.rtti;
import cherry.core.value;
import cherry.platform.render : Thickness;
import cherry.ui.controls.control;
import cherry.ui.controls.textblock;
import cherry.ui.element;
import cherry.ui.event;
import cherry.ui.input;

/**
 * Something to press.
 *
 * The behaviour is the whole of it: press, drag off, drag back, release,
 * and the click that follows only when the pointer was still over the button
 * at the end.  What it looks like is Control's business today and a template's
 * tomorrow, which is the separation WPF draws between a Button and the chrome
 * its theme wraps around one -- with the difference that we are not going to
 * need a chrome, because a flat button is a fill, a border and a label.
 *
 * **The label is an ordinary child.** Button builds a TextBlock in its
 * constructor and pushes Text into it; Control already measures and arranges
 * children inside the padding, so nothing here overrides either.  The cost is
 * that `children` contains something the caller did not put there -- the price
 * of having no content model, and the first thing a ContentPresenter will take
 * over.
 *
 * **The behaviour is class handling**: it overrides Element's handleMouseXxx
 * hooks rather than subscribing to its own events, so that none of it stands in
 * the queue the code using a button subscribes to.  Nothing here can be
 * unsubscribed, reordered, or run at a moment that depends on when somebody
 * else happened to subscribe.
 *
 * **It marks MouseDown and MouseUp as handled**, because a press on a button is
 * not also a press on whatever the button sits in -- and that still has a
 * consequence worth knowing.  A handled event skips the handlers after it on
 * the same element, and the class tier runs before all of them, so a handler
 * added to a button's MouseDown does not run at all unless it was added with
 * handledEventsToo.  WPF's ButtonBase behaves the same way and answers it the
 * same way: watch IsPressed and IsMouseOver, or use Click.  Both are
 * properties, so both report through onPropertyChanged, which is where a style
 * trigger will hang when there are styles.
 *
 * **The keyboard works the way Windows does**, which is not the way the mouse
 * does: Space presses on the way down and clicks on the way up, so it can be
 * taken back by moving the focus away before letting go; Enter clicks
 * immediately, and a held Enter clicks again on every repeat, exactly as a
 * native button and WPF's both do.
 */
class Button : Control
{
    shared static this()
    {
        // The text goes into the label, so the label's own measure is what
        // invalidates layout -- nothing to declare here beyond the push.
        PropertyMetadata textMeta;
        textMeta.defaultValue = Value("");
        textMeta.onPropertyChanged ~= &textChanged;

        textProperty = Property.register("text",
            getRtti!string(), getRtti!Button(), textMeta);

        // Written by the press logic and by nothing else, so it takes a key.
        // No affectsRender: an appearance that depends on it says so itself,
        // which for now is this class asking for a repaint when it changes.
        PropertyMetadata pressedMeta;
        pressedMeta.defaultValue = Value(false);

        isPressedKey = Property.registerReadOnly("isPressed",
            getRtti!bool(), getRtti!Button(), pressedMeta);

        // Neither changes how the button looks or how big it is.  A theme that
        // wants to mark the default one draws on IsDefault itself, the way it
        // draws on IsPressed.
        PropertyMetadata actionMeta;
        actionMeta.defaultValue = Value(false);

        isDefaultProperty = Property.register("isDefault",
            getRtti!bool(), getRtti!Button(), actionMeta);
        isCancelProperty = Property.register("isCancel",
            getRtti!bool(), getRtti!Button(), actionMeta);

        clickEvent = RoutedEvent.register("onClick", RoutingStrategy.bubble, getRtti!Button());
    }

    static immutable(Property) textProperty;
    static immutable(Property) isDefaultProperty;
    static immutable(Property) isCancelProperty;
    static immutable(RoutedEvent) clickEvent;

   /**
    * Whether Enter presses this button from anywhere in the window, and
    * whether Escape does.
    *
    * "From anywhere" means from wherever the keyboard is, once whatever has it
    * has declined the key -- a text field that wants Enter for itself keeps it,
    * and this never hears about it.  A focused button is pressed by Enter
    * whether or not it is the default one, so the default button of a window
    * that has the keyboard on another button does not also fire.
    *
    * One of each per window: there are no focus scopes, so the first one the
    * tree offers in document order is the one that answers.
    */
    @property bool isDefault() const
    {
        return getValue(isDefaultProperty).get!bool;
    }

    /// ditto
    @property void isDefault(bool value)
    {
        setValue(isDefaultProperty, Value(value));
    }

    /// ditto
    @property bool isCancel() const
    {
        return getValue(isCancelProperty).get!bool;
    }

    /// ditto
    @property void isCancel(bool value)
    {
        setValue(isCancelProperty, Value(value));
    }

   /**
    * How the window finds this button when nothing claimed an Enter or an
    * Escape.  See Element for why it asks rather than being told.
    */
    override @property bool isDefaultAction() const
    {
        return isDefault;
    }

    /// ditto
    override @property bool isCancelAction() const
    {
        return isCancel;
    }

   /**
    * Whether the button is being held down.
    *
    * True from the press until the release, and false again the moment the
    * pointer leaves -- so a button dragged off goes back to looking untouched
    * while still holding the pointer, and lights up again if the pointer
    * returns.  That is what tells somebody mid-press that letting go now will
    * do nothing.
    */
    static @property immutable(Property) isPressedProperty() pure nothrow
    {
        return isPressedKey.property;
    }

    /// ditto
    @property bool isPressed() const
    {
        return getValue(isPressedProperty).get!bool;
    }

    /// The words on it.
    @property string text() const
    {
        return getValue(textProperty).get!string;
    }

    /// ditto
    @property void text(string value)
    {
        setValue(textProperty, Value(value));
    }

   /**
    * Raised when the button is pressed and released over itself.
    *
    * Bubbling, so a window can listen once for a panel full of buttons and read
    * args.source to learn which was pressed.
    */
    @event @property auto onClick()
    {
        return routedAccessor(this, clickEvent);
    }

    this()
    {
        padding = Thickness(12, 5);

        _label = new TextBlock;
        _label.horizontalAlignment = HorizontalAlignment.center;
        _label.verticalAlignment = VerticalAlignment.center;
        addChild(_label);
    }

protected:
    override void handleMouseDown(RoutedEventArgs args)
    {
        super.handleMouseDown(args);

        auto mouse = cast(MouseEventArgs) args;
        if (mouse is null || mouse.button != MouseButton.left)
            return;

        // The capture is what makes the rest of this work: without it a release
        // anywhere else goes to whatever is under the pointer and this button
        // stays pressed for good.
        captureMouse();
        setPressed(true);

        // Claimed: a press on a button is not also a press on whatever the
        // button happens to be sitting in.
        args.handled = true;
    }

    override void handleMouseUp(RoutedEventArgs args)
    {
        super.handleMouseUp(args);

        auto mouse = cast(MouseEventArgs) args;
        if (mouse is null || mouse.button != MouseButton.left)
            return;

        immutable clicked = isPressed;

        // Released first, and unconditionally.  Every way out of a press has to
        // give the pointer back, and a handler of Click that opens a modal
        // dialog must not do it while this button still holds the mouse.
        releaseMouseCapture();
        setPressed(false);

        args.handled = true;

        if (clicked)
            raiseEvent(new RoutedEventArgs(clickEvent));
    }

    override void handleMouseMove(RoutedEventArgs args)
    {
        super.handleMouseMove(args);

        // Only while holding the pointer, and then only to follow it: pressed
        // means "the pointer is down and still on me", and isMouseOver keeps
        // saying where it really is even under a capture.
        if (isMouseCaptured)
            setPressed(isMouseOver);
    }

    override void handleMouseEnter(RoutedEventArgs args)
    {
        super.handleMouseEnter(args);
        crossedTheEdge();
    }

    override void handleMouseLeave(RoutedEventArgs args)
    {
        super.handleMouseLeave(args);
        crossedTheEdge();
    }

    override void handleMouseCaptureLost(RoutedEventArgs args)
    {
        super.handleMouseCaptureLost(args);

        // The system takes the pointer away for reasons of its own -- a task
        // switch, a menu, another window.  Without this the button would be
        // left looking pressed with nothing able to release it.
        setPressed(false);
    }

    override void handleKeyDown(RoutedEventArgs args)
    {
        super.handleKeyDown(args);

        auto pressed = cast(KeyEventArgs) args;
        if (pressed is null)
            return;

        // Space holds the button down and clicks on the way up, so somebody who
        // changed their mind can move the focus away before letting go.  That
        // is the keyboard's version of dragging the pointer off, and it is why
        // the two keys are not the same key with different names.
        if (pressed.key == Key.space)
        {
            setPressed(true);
            args.handled = true;
            return;
        }

        // Enter acts at once, and again on every repeat while it is held.  Both
        // a native button and WPF's do this, and it is what makes holding Enter
        // on a spin button work.
        //
        // Escape only when this is the cancel button -- otherwise Escape on a
        // focused button would press it, which is the one thing somebody
        // pressing Escape certainly did not mean.
        if (pressed.key == Key.enter || (pressed.key == Key.escape && isCancel))
        {
            args.handled = true;
            raiseEvent(new RoutedEventArgs(clickEvent));
        }
    }

    override void handleKeyUp(RoutedEventArgs args)
    {
        super.handleKeyUp(args);

        auto released = cast(KeyEventArgs) args;
        if (released is null || released.key != Key.space)
            return;

        immutable clicked = isPressed;

        setPressed(false);
        args.handled = true;

        if (clicked)
            raiseEvent(new RoutedEventArgs(clickEvent));
    }

    override void handleLostFocus(RoutedEventArgs args)
    {
        super.handleLostFocus(args);

        // The keyboard's mouseCaptureLost.  A button held down with Space and
        // then Tabbed away from never sees the key come back up -- that event
        // goes to whatever has the keyboard now -- so this is the only thing
        // that can undo the press.
        //
        // Unless the pointer is holding it, in which case the press is the
        // mouse's and the mouse will finish it.
        if (!isMouseCaptured)
            setPressed(false);
    }

private:
    void crossedTheEdge()
    {
        // Crossing the edge with the button held is the case this exists for.
        // Crossing it otherwise changes nothing, because pressed is false
        // either way -- but the appearance depends on the pointer being over
        // it, so the repaint is asked for regardless.
        if (isMouseCaptured)
            setPressed(isMouseOver);

        invalidateVisual();
    }

    void setPressed(bool value)
    {
        if (isPressed == value)
            return;

        setValue(isPressedKey, Value(value));

        // IsPressed carries no affectsRender, deliberately -- see its
        // registration.  The control that changes appearance says so, and this
        // is it saying so.
        invalidateVisual();
    }

   /*
    * Pushes the text into the label, the way Window pushes its title to the
    * platform: the property is the thing that can be bound and styled, the
    * label is where it ends up.
    */
    static void textChanged(const(Object) obj, const(Value) oldValue, const(Value) newValue)
    {
        auto button = cast(Button) cast() obj;
        if (button is null || button._label is null)
            return;

        button._label.text = newValue.get!string;
    }

    static immutable(ReadOnlyPropertyKey) isPressedKey;

    TextBlock _label;
}

version (unittest)
{
    import cherry.platform.render : Rect, Size;
    import cherry.platform.window : PlatformWindow, PlatformWindowHost;
    import cherry.ui.testing : makeWindow, TestWindow;

   /*
    * A window with one button pinned to the top left, laid out and ready to be
    * pressed at coordinates a test can name.
    *
    * The button is 100 by 40 at the origin, so (50, 20) is on it and (300, 200)
    * is nowhere near.
    */
    private struct Bench
    {
        TestWindow window;
        Button button;

        alias button this;
    }

    private Bench bench()
    {
        auto w = makeWindow();

        auto button = new Button;
        button.text = "Press";
        button.width = 100;
        button.height = 40;
        button.horizontalAlignment = HorizontalAlignment.left;
        button.verticalAlignment = VerticalAlignment.top;

        w.window.addChild(button);
        w.window.updateLayout();

        return Bench(w, button);
    }
}

unittest
{
    // The text goes into the label, and the label is what the layout measures.
    auto b = bench();

    assert(b.button.childCount == 1, "the label the caller did not add");

    auto label = cast(TextBlock) b.button.children[0];
    assert(label !is null && label.text == "Press");

    b.button.text = "Other";
    assert(label.text == "Other", "the property pushes, the label holds");
}

unittest
{
    // The ordinary press: down on it, up on it, one click -- and the pointer is
    // taken and given back exactly once.
    auto b = bench();

    int clicks;
    Element clickedOn;
    b.button.onClick ~= (Element sender, RoutedEventArgs args) {
        ++clicks;
        clickedOn = args.source;
    };

    b.window.platform.host.onMouseMove(50, 20);
    b.window.platform.host.onMouseDown(MouseButton.left, 50, 20);

    assert(b.button.isPressed);
    assert(b.button.isMouseCaptured);
    assert(b.window.platform.captures == 1);
    assert(clicks == 0, "a press is not a click");

    b.window.platform.host.onMouseUp(MouseButton.left, 50, 20);

    assert(clicks == 1);
    assert(clickedOn is b.button, "and the args name which button it was");
    assert(!b.button.isPressed);
    assert(!b.button.isMouseCaptured);
    assert(b.window.platform.releases == 1);
}

unittest
{
    // Pressed, dragged off, released elsewhere: no click, and the pointer is
    // handed back all the same.
    auto b = bench();

    int clicks;
    b.button.onClick ~= (Element sender, RoutedEventArgs args) { ++clicks; };

    b.window.platform.host.onMouseMove(50, 20);
    b.window.platform.host.onMouseDown(MouseButton.left, 50, 20);
    assert(b.button.isPressed);

    // Off the button.  It still holds the pointer, so it still hears the move.
    b.window.platform.host.onMouseMove(300, 200);
    assert(!b.button.isPressed, "letting go here would do nothing, and it says so");
    assert(b.button.isMouseCaptured, "but it is still the one being dragged");

    // Back on, and it arms again.
    b.window.platform.host.onMouseMove(60, 25);
    assert(b.button.isPressed);

    // Off again, and release out there.
    b.window.platform.host.onMouseMove(300, 200);
    b.window.platform.host.onMouseUp(MouseButton.left, 300, 200);

    assert(clicks == 0, "released somewhere else, so nothing happened");
    assert(!b.button.isMouseCaptured);
    assert(b.window.platform.releases == 1, "and the pointer was still given back");
}

unittest
{
    // The system takes the pointer away mid-press -- a task switch, a menu.
    // The button must not be left looking held.
    auto b = bench();

    int clicks;
    b.button.onClick ~= (Element sender, RoutedEventArgs args) { ++clicks; };

    b.window.platform.host.onMouseMove(50, 20);
    b.window.platform.host.onMouseDown(MouseButton.left, 50, 20);
    assert(b.button.isPressed);

    b.window.platform.host.onMouseCaptureLost();

    assert(!b.button.isPressed);
    assert(!b.button.isMouseCaptured);
    assert(clicks == 0);
}

unittest
{
    // Only the left button presses it, and a press is claimed so that whatever
    // the button sits in does not treat it as a press of its own.
    auto b = bench();

    b.window.platform.host.onMouseDown(MouseButton.right, 50, 20);
    assert(!b.button.isPressed);
    assert(!b.button.isMouseCaptured);

    int windowHeard;
    b.window.window.onMouseDown ~= (Element sender, RoutedEventArgs args) { ++windowHeard; };

    b.window.platform.host.onMouseDown(MouseButton.left, 50, 20);
    assert(b.button.isPressed);
    assert(windowHeard == 0, "claimed on the way up");
}

unittest
{
    // What an appearance has to hang off, and why it cannot be the mouse
    // events: the button class-handles those and marks them handled, and the
    // class tier runs before the queue, so a handler on the same element never
    // runs at all.  IsPressed and IsMouseOver report through onPropertyChanged
    // instead, and they report every change.
    static class Watcher : Button
    {
        string[] seen;

        protected override void onPropertyChanged(immutable(Property) property,
                                                  ref immutable(PropertyMetadata) metadata,
                                                  const(Value) oldValue,
                                                  const(Value) newValue)
        {
            super.onPropertyChanged(property, metadata, oldValue, newValue);

            if (property is Button.isPressedProperty)
                seen ~= newValue.get!bool ? "pressed" : "released";
            else if (property is Element.isMouseOverProperty)
                seen ~= newValue.get!bool ? "over" : "out";
        }
    }

    auto w = makeWindow();

    auto button = new Watcher;
    button.width = 100;
    button.height = 40;
    button.horizontalAlignment = HorizontalAlignment.left;
    button.verticalAlignment = VerticalAlignment.top;
    w.window.addChild(button);
    w.window.updateLayout();

    int afterwards;
    button.onMouseDown ~= (Element sender, RoutedEventArgs args) { ++afterwards; };

    w.platform.host.onMouseMove(50, 20);
    w.platform.host.onMouseDown(MouseButton.left, 50, 20);
    w.platform.host.onMouseMove(300, 200);
    w.platform.host.onMouseMove(50, 20);
    w.platform.host.onMouseUp(MouseButton.left, 50, 20);

    assert(button.seen == ["over", "pressed", "out", "released", "over", "pressed", "released"],
           "every crossing and every press, in the order they happened");

    assert(afterwards == 0,
           "and the handler on the button never saw the press -- "
           ~ "which is why an appearance must not be hung off these events");
}

unittest
{
    // Where the button's behaviour actually lives now: not in the queue.
    //
    // A handler asking for handled events too runs, and finds the press already
    // dealt with -- press taken, pointer captured, event claimed -- before it
    // was ever given a turn.  That is the class tier: the control does not
    // queue up behind the code using it, and does not make that code wait
    // behind the control either.
    auto b = bench();

    bool ran;
    bool alreadyHandled;
    bool alreadyPressed;

    b.button.addEventHandler(mouseDownEvent,
        (Element sender, RoutedEventArgs args) {
            ran = true;
            alreadyHandled = args.handled;
            alreadyPressed = (cast(Button) sender).isPressed;
        }, true);

    b.window.platform.host.onMouseMove(50, 20);
    b.window.platform.host.onMouseDown(MouseButton.left, 50, 20);

    assert(ran, "handledEventsToo is the way in");
    assert(alreadyHandled, "and it arrives after the button has claimed the press");
    assert(alreadyPressed);
}

unittest
{
    // Click bubbles, so one handler on the window serves a panel of buttons.
    auto b = bench();

    Element heard;
    b.window.window.addEventHandler(Button.clickEvent,
        (Element sender, RoutedEventArgs args) { heard = args.source; });

    b.window.platform.host.onMouseMove(50, 20);
    b.window.platform.host.onMouseDown(MouseButton.left, 50, 20);
    b.window.platform.host.onMouseUp(MouseButton.left, 50, 20);

    assert(heard is b.button);
}

unittest
{
    // Space holds the button and clicks when it comes back up.
    auto b = bench();
    b.button.focus();

    int clicks;
    b.button.onClick ~= (Element sender, RoutedEventArgs args) { ++clicks; };

    b.window.platform.host.onKeyDown(Key.space, ModifierKeys.none, false);

    assert(b.button.isPressed, "held, and looking it");
    assert(clicks == 0, "a press is not a click");

    // Holding it changes nothing: the press is already on.
    b.window.platform.host.onKeyDown(Key.space, ModifierKeys.none, true);
    assert(b.button.isPressed && clicks == 0);

    b.window.platform.host.onKeyUp(Key.space, ModifierKeys.none);

    assert(clicks == 1);
    assert(!b.button.isPressed);
}

unittest
{
    // Enter acts at once, and again on every repeat -- a native button and
    // WPF's both do this.
    auto b = bench();
    b.button.focus();

    int clicks;
    b.button.onClick ~= (Element sender, RoutedEventArgs args) { ++clicks; };

    b.window.platform.host.onKeyDown(Key.enter, ModifierKeys.none, false);
    assert(clicks == 1);
    assert(!b.button.isPressed, "Enter does not hold it down, it presses it");

    b.window.platform.host.onKeyDown(Key.enter, ModifierKeys.none, true);
    assert(clicks == 2);

    b.window.platform.host.onKeyUp(Key.enter, ModifierKeys.none);
    assert(clicks == 2, "and the release adds nothing");
}

unittest
{
    // The keyboard's version of dragging off: Space down, focus away, and
    // nothing happened.  The button never sees the key come up -- by then the
    // keyboard is somewhere else -- so losing the focus is what undoes it.
    auto b = bench();

    auto other = new Button;
    b.window.window.addChild(other);
    b.window.window.updateLayout();

    b.button.focus();

    int clicks;
    b.button.onClick ~= (Element sender, RoutedEventArgs args) { ++clicks; };

    b.window.platform.host.onKeyDown(Key.space, ModifierKeys.none, false);
    assert(b.button.isPressed);

    other.focus();

    assert(!b.button.isPressed, "let go of it, and say so");
    assert(clicks == 0);

    // The key comes up at the other button, which was never pressed.
    b.window.platform.host.onKeyUp(Key.space, ModifierKeys.none);
    assert(clicks == 0, "nothing happened, which is what was asked for");
}

unittest
{
    // A key the button has no use for is left alone, so it goes on up and the
    // platform still gets its turn.
    auto b = bench();
    b.button.focus();

    assert(!b.window.platform.host.onKeyDown(Key.f4, ModifierKeys.alt, false));
    assert(b.window.platform.host.onKeyDown(Key.space, ModifierKeys.none, false),
           "but the ones it presses on are claimed");
}

unittest
{
    // Clicking a button puts the keyboard on it, which is Control's doing and
    // reaches Button through the super call at the top of its own hook.
    auto b = bench();

    assert(!b.button.isFocused);

    b.window.platform.host.onMouseMove(50, 20);
    b.window.platform.host.onMouseDown(MouseButton.left, 50, 20);

    assert(b.button.isFocused);
    assert(b.button.isPressed, "and the press still happened");
}

unittest
{
    // Enter reaches the default button from wherever the keyboard is.
    auto b = bench();
    b.button.isDefault = true;

    auto elsewhere = new Button;
    b.window.window.addChild(elsewhere);
    b.window.window.updateLayout();

    int clicks;
    b.button.onClick ~= (Element sender, RoutedEventArgs args) { ++clicks; };

    int otherClicks;
    elsewhere.onClick ~= (Element sender, RoutedEventArgs args) { ++otherClicks; };

    // Nothing focused at all: the key starts at the window and is passed on.
    assert(b.window.platform.host.onKeyDown(Key.enter, ModifierKeys.none, false));
    assert(clicks == 1);

    // The keyboard on another button: that one takes Enter for itself, and the
    // default button does not also fire.
    elsewhere.focus();
    b.window.platform.host.onKeyDown(Key.enter, ModifierKeys.none, false);

    assert(otherClicks == 1);
    assert(clicks == 1, "a focused button is pressed by Enter, default or not");
}

unittest
{
    // Escape reaches the cancel button, and only the cancel button.
    auto b = bench();

    auto cancel = new Button;
    cancel.isCancel = true;
    b.window.window.addChild(cancel);
    b.window.window.updateLayout();

    int cancelled;
    cancel.onClick ~= (Element sender, RoutedEventArgs args) { ++cancelled; };

    int pressed;
    b.button.onClick ~= (Element sender, RoutedEventArgs args) { ++pressed; };

    // Even with the keyboard on an ordinary button, which does not treat
    // Escape as a press of itself.
    b.button.focus();
    assert(b.window.platform.host.onKeyDown(Key.escape, ModifierKeys.none, false));

    assert(cancelled == 1);
    assert(pressed == 0, "Escape on a button is not a press of it");
}

unittest
{
    // Something that answers yes and then does nothing with the key must not
    // send it round again.
    static class Deaf : Button
    {
        override @property bool isDefaultAction() const { return true; }

        protected override void handleKeyDown(RoutedEventArgs args)
        {
            // Deliberately not calling super: it claims nothing and leaves the
            // event to carry on bubbling, which is the loop worth proving does
            // not happen.
        }
    }

    auto w = makeWindow();
    auto deaf = new Deaf;
    w.window.addChild(deaf);
    w.window.updateLayout();

    assert(!w.platform.host.onKeyDown(Key.enter, ModifierKeys.none, false),
           "nobody handled it, and the window did not try forever");
}

unittest
{
    // With no default button, Enter is left for the platform.
    auto b = bench();

    assert(!b.window.platform.host.onKeyDown(Key.enter, ModifierKeys.none, false));
    assert(!b.window.platform.host.onKeyDown(Key.escape, ModifierKeys.none, false));
}
