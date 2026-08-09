module cherry.ui.window;

import cherry.ui.application : UIApplication;
import cherry.core.multicast;
import cherry.core.property;
import cherry.core.rtti;
import cherry.core.value;
import cherry.platform;
import cherry.ui.element;
import cherry.ui.event;
import cherry.ui.input;
import cherry.ui.visual : Visual;


/**
 * A delegate type for handling a window that is about to close.
 *
 * The decision travels as a ref parameter rather than a return value: a
 * Multicast hands back only the last handler's result, so a returned bool
 * would quietly discard every subscriber but one.  With a ref, any of them
 * can object, and each sees whether an earlier one already did.
 */
alias WindowClosingHandler = void delegate(Window window, ref bool cancel);

/**
 * A top-level window: the root of an element tree bound to a native window
 * surface.
 *
 * Title, width and height are dependency properties; changing them pushes
 * the new values to the platform, and platform-driven changes (the user
 * resizing the window) flow back into the properties without echoing.
 * Native input arrives through a private PlatformWindowHost adapter, is
 * hit-tested against the tree, and is raised as a routed event on the deepest
 * element under the pointer -- so the platform plumbing does not leak into the
 * window's public API, and a handler on an ancestor still hears it on the way
 * up.
 */
class Window : Element
{
    shared static this()
    {
        PropertyMetadata titleMeta;
        titleMeta.defaultValue = Value("Window");
        titleMeta.onPropertyChanged ~= &titleChanged;
        titleProperty = Property.register("Title", getRtti!string(), getRtti!Window(), titleMeta);

        // Width and Height belong to Element -- every element has a size, and
        // a window is not the exception.  What differs is what the size means
        // here: unset is no answer for something the OS must be handed a
        // number for, and a change has to reach the native window.  Both of
        // those are metadata, not grounds for a second pair of properties.
        PropertyMetadata widthMeta;
        widthMeta.defaultValue = Value(600.0f);
        widthMeta.onPropertyChanged ~= &sizeChanged;
        widthProperty.overrideMetadata(getRtti!Window(), widthMeta);

        PropertyMetadata heightMeta;
        heightMeta.defaultValue = Value(400.0f);
        heightMeta.onPropertyChanged ~= &sizeChanged;
        heightProperty.overrideMetadata(getRtti!Window(), heightMeta);
    }

    static immutable(Property) titleProperty;

    @property string title() const
    {
        return getValue(titleProperty).get!string;
    }

    @property void title(string value)
    {
        setValue(titleProperty, Value(value));
    }

	/**
    * Raised when the window is about to close, whether the request came from
    * the user or from close().  Setting cancel keeps the window open; pair
    * that with hide() to make the close button put the window away instead.
    *
    * Shutting the application down does not raise this: by then the decision
    * has been made elsewhere, and a window is not entitled to veto it.
    */
    @event @property auto onClosing()
    {
        return eventAccessor(&_onClosing);
    }

   /**
    * Raised after the native window has been destroyed.  A plain Multicast
    * event: window lifetime is not a tree concern, so it does not route.
    * Declared through the @event accessor pattern: subscription-only from
    * the outside, raised only by the window itself.
    */
    @event @property auto onClosed()
    {
        return eventAccessor(&_onClosed);
    }

   /**
    * Creates a window backed by the platform's native implementation.
    */
    this()
    {
        this((PlatformWindowHost host) => createPlatformWindow(host));
    }

   /**
    * Creates a window backed by the factory's PlatformWindow -- the seam
    * used by tests to substitute a fake platform.
    */
    this(scope PlatformWindow delegate(PlatformWindowHost) platformFactory)
    in {
        assert(platformFactory !is null);
    }
    do {
        /*auto app = UIApplication.instance;
        if (app is null)
            throw new Exception("Window requires a UIApplication instance.");*/

        _platform = platformFactory(new PlatformHost);

        // Push the effective (default or preset) values to the platform.
        _platform.setTitle(getValue(titleProperty).get!string);
        _platform.setClientSize(cast(int) width, cast(int) height);

        // Lay the tree out once here, so an element added to a brand new
        // window can be asked for its actualWidth without first waiting for
        // whatever resize the platform happens to report.
        performLayout();

        // Register new Window object in UIApplication
        if (UIApplication.instance !is null)
		{
            UIApplication.instance.registerWindow(this);
            _registered = true;
        }
    }

   /**
    * Makes the window visible.
    */
    void show()
    {
        verifyAlive();
        _platform.show();
    }

   /**
    * Takes the window off the screen without destroying it.
    *
    * This is the reversible counterpart of close(): the native window, its
    * renderer and its place in the application's window list all survive, so
    * show() brings it back where it was.  An application that wants its
    * close button to tuck the window away rather than end it cancels
    * onClosing and calls this.
    */
    void hide()
    {
        verifyAlive();
        _platform.hide();
    }

   /**
    * Schedules a repaint of the whole window content.
    *
    * Silent on a window that has been closed, rather than throwing the way
    * show() and hide() do.  Those are asked to do something; this one is told
    * something needs redrawing, and on a window that is gone the honest
    * answer is that there is nothing to do -- not that the caller erred.  A
    * handler running from onClosed has every right to touch the tree.
    */
    void invalidate()
    {
        if (_destroyed)
            return;

        _platform.invalidate();
    }

   /**
    * Asks the window to close, raising onClosing first: a handler that sets
    * cancel keeps the window alive, exactly as it does when the request came
    * from the window's own close button.
    *
    * Closing destroys the native window -- it is not the reverse of show().
    * Closing an already closed window does nothing.
    */
    void close()
    {
        if (_destroyed)
            return;

        bool cancel;
        _onClosing(this, cancel);

        if (!cancel)
            forceClose();
    }

package(cherry):
   /**
    * Destroys the window without asking, for the application shutting down.
    */
    void forceClose()
    {
        if (_destroyed)
            return;

        _platform.close();
    }

   /**
    * Called when the application gains or loses the foreground.
    *
    * A plain delegate rather than an event: there is one application, and it
    * is the only thing entitled to hear this.  It is wired on a single
    * window -- the main one -- because the platform tells every top-level
    * window and the application wants to hear it once.
    */
    void delegate(bool active) activatedCallback;

   /**
    * Called when the session is ending; returning false asks to stop it.
    *
    * Wired on a single window for the same reason, and safely so: a window
    * without the callback agrees, and one refusal anywhere is enough to stop
    * the session.
    */
    bool delegate(SessionEndReason reason) sessionEndingCallback;

public:
   /**
    * The native window surface backing this window.
    */
    @property PlatformWindow platformWindow() pure nothrow @nogc
    {
        return _platform;
    }

private:
   /*
    * Adapter receiving the platform driver's notifications.  A nested class
    * so the host methods stay out of Window's public API and cannot collide
    * with user-facing names (e.g. the onMouseDown accessor).
    */
    final class PlatformHost : PlatformWindowHost
    {
        void onCloseRequested()
        {
            // Default policy: closing is allowed.  A cancellable Closing
            // event can hook in here later.
            this.outer.close();
        }

        void onDestroyed()
        {
            this.outer.handleDestroyed();
        }

        void onResized(int width, int height)
        {
            this.outer.handleResized(width, height);
        }

        void onPaintRequested()
        {
            this.outer.handlePaintRequested();
        }

        void onActivationChanged(bool active)
        {
            if (this.outer.activatedCallback !is null)
                this.outer.activatedCallback(active);
        }

        bool onSessionEnding(SessionEndReason reason)
        {
            // Nobody listening on this window means nobody objects through
            // it; another window may still refuse.
            if (this.outer.sessionEndingCallback is null)
                return true;

            return this.outer.sessionEndingCallback(reason);
        }

        void onMouseDown(MouseButton button, int x, int y)
        {
            this.outer.raiseMouseEvent(mouseDownEvent, button, x, y);
        }

        void onMouseUp(MouseButton button, int x, int y)
        {
            this.outer.raiseMouseEvent(mouseUpEvent, button, x, y);
        }

        void onMouseMove(int x, int y)
        {
            this.outer.handleMouseMove(x, y);
        }

        void onMouseLeave()
        {
            this.outer.handleMouseLeave();
        }
    }

   /*
    * The pointer went somewhere else entirely, so everything it was over is
    * left -- with the position it was last seen at, since there is no new one.
    */
    void handleMouseLeave()
    {
        updateMouseOver(_mouseOver, null, _lastMouseX, _lastMouseY);
        _mouseOver = null;
    }

   /*
    * Moves the pointer, then reports that it moved.
    *
    * That order is the point.  Enter and leave settle first, so a MouseMove
    * handler reading isMouseOver -- on itself or on anything around it -- reads
    * where the pointer is now rather than where it was a moment ago.
    */
    void handleMouseMove(int x, int y)
    {
        auto target = hitElement(x, y);

        _lastMouseX = x;
        _lastMouseY = y;

        updateMouseOver(_mouseOver, target, x, y);
        _mouseOver = target;

        target.raiseEvent(new MouseEventArgs(mouseMoveEvent, MouseButton.none, x, y));
    }

   /*
    * Raises a mouse event on whatever is under the pointer.
    *
    * The route starts at the deepest element and travels up, so a handler on
    * this window still hears about a click on a button four levels down -- and
    * hears it with args.source naming the button.  Before there was
    * hit-testing this raised on the window itself, which made every route one
    * step long and every bubbling event a direct one in disguise.
    */
    void raiseMouseEvent(immutable(RoutedEvent) event, MouseButton button, int x, int y)
    {
        hitElement(x, y).raiseEvent(new MouseEventArgs(event, button, x, y));
    }

   /*
    * The element under a client-area point, or the window itself.
    *
    * A client point needs no adjustment on the way in: hitTest takes its
    * argument in the visual's parent space, and a window's placement is the
    * client area's origin.
    *
    * The walk up is for a hit that is a Visual and not an Element -- a
    * lightweight drawing node, once such things exist.  A routed event has to
    * start at an Element, so the nearest one above the hit is what carries the
    * route.  Today the loop never takes a second step, because every visual in
    * the tree is an element; it is here so that adding one that is not cannot
    * quietly break input.
    */
    Element hitElement(float x, float y)
    {
        for (Visual v = hitTest(Point(x, y)); v !is null; v = v.visualParent)
            if (auto element = cast(Element) v)
                return element;

        return this;
    }

    void handleDestroyed()
    {
        _destroyed = true;
        handleDisposedRenderer();

        // Unregister this Window object from UIApplication
        if (_registered)
            UIApplication.instance.unregisterWindow(this);  

        _onClosed(this);
    }

   /*
    * Using a window whose native surface is gone would work on a stale
    * handle and quietly do nothing, so say so instead -- and point at the
    * call that was probably meant.
    */
    void verifyAlive() const
    {
        if (_destroyed)
            throw new Exception(
                "The window has been closed and cannot be shown again. "
                ~ "To take a window off the screen and bring it back, use hide().");
    }

    void handlePaintRequested()
    {
        // The renderer is created on the first real paint request: fakes
        // without a native handle (headless tests) never get here.
        if (_renderer is null)
        {
            if (_platform.nativeHandle is null)
                return;

            _renderer = createWindowRenderer(_platform);
        }

        _renderer.render((DrawingContext context) {
            context.clear(Color.white);
            renderSubtree(context);
        });
    }

    void handleDisposedRenderer()
    {
        if (_renderer !is null)
        {
            _renderer.dispose();
            _renderer = null;
        }
    }

    void handleResized(int width, int height)
    {
        if (_renderer !is null)
            _renderer.resize(width, height);

        // Reflect the platform size into the properties without echoing it
        // back through the change callbacks.
        //
        // The window keeps Width and Height truthful instead of leaving them
        // at whatever was asked for: the property system notifies only on a
        // change, so a stale Width would turn re-assigning the original number
        // into a silent no-op.
        {
            _syncingFromPlatform = true;
            scope (exit) _syncingFromPlatform = false;

            setValue(widthProperty, Value(cast(float) width));
            setValue(heightProperty, Value(cast(float) height));
        }

        // Width and Height carry affectsMeasure, so the assignments above have
        // already marked this window and queued a pass.  It is run here rather
        // than left to the queue because a resize arrives inside the platform's
        // own message handling, and the frame showing the new size is the very
        // next thing the platform will ask for.
        //
        // Going through the pass rather than laying out directly means the
        // queued one is consumed instead of duplicated, that a resize which
        // does not change the numbers -- Windows sends plenty -- costs nothing,
        // and that anything else that went out of date since the last pass is
        // settled in this one rather than in a second after the paint.
        updateLayout();
    }

   /*
    * The window is the root of its tree: nothing above it dictates a size, so
    * the space the platform granted is the space the layout works within.
    *
    * Goes through the two root entry points rather than repeating their
    * arithmetic, so the constructor's path and the resize path cannot drift
    * apart.
    */
    void performLayout()
    {
        measureAsRoot();
        arrangeAsRoot();
    }

   /*
    * A window is the one element whose size is dictated from outside the tree,
    * so it is the one for which the last question it was asked is not the best
    * answer available.  Width and Height are, because handleResized keeps them
    * truthful about what the platform granted.
    *
    * The margin is added here and taken straight back out by the generic code
    * below, which is the point: a margin says where an element sits inside a
    * parent's slot, and a window has no parent to sit inside.  Left alone it
    * would inset the content at the top left and push the same amount off the
    * bottom right, since a window's Width is always set and so its content is
    * arranged at exactly that width.  Cancelling it makes a Margin on a Window
    * cost nothing instead of quietly costing the bottom right corner.  With no
    * margin -- which is every window that never sets one -- this is the same
    * arithmetic it always was.
    */
    public override void measureAsRoot()
    {
        immutable m = margin;
        measure(Size(width + m.horizontal, height + m.vertical));
    }

    /// ditto
    public override void arrangeAsRoot()
    {
        immutable m = margin;
        arrange(Rect(-m.left, -m.top, width + m.horizontal, height + m.vertical));
    }

   /*
    * The window is a surface, so a repaint asked of the tree stops here and
    * becomes a repaint asked of the platform.
    *
    * Silent on a destroyed window rather than throwing: this runs inside a
    * layout pass, and a throw would take that pass down for every other
    * window on the dispatcher and trip its scope(failure).  One closed window
    * is not grounds for losing everyone else's frame.
    */
    public override void repaintAsRoot(Rect region)
    {
        if (_destroyed)
            return;

        _platform.invalidate(region);
    }

    static void titleChanged(const(Object) obj, const(Value) oldValue, const(Value) newValue)
    {
        auto window = cast(Window) cast() obj;
        if (window is null || window._syncingFromPlatform
            || window._platform is null || window._destroyed)
            return;

        window._platform.setTitle(newValue.get!string);
    }

    static void sizeChanged(const(Object) obj, const(Value) oldValue, const(Value) newValue)
    {
        auto window = cast(Window) cast() obj;
        if (window is null || window._syncingFromPlatform
            || window._platform is null || window._destroyed)
            return;

        window._platform.setClientSize(cast(int) window.width, cast(int) window.height);
    }

    PlatformWindow _platform;
    WindowRenderer _renderer;
    // The element the pointer was over when it was last heard from, so the
    // next notification can work out what changed.  Null before the pointer
    // has ever been in the window, and again once it has left.
    Element        _mouseOver;
    // Where it was when it was last seen, so that leaving -- which carries no
    // position, the pointer being elsewhere by then -- has one to report.
    float          _lastMouseX = 0;
    float          _lastMouseY = 0;
    Multicast!(void delegate(Window)) _onClosed;
    Multicast!WindowClosingHandler _onClosing;
    bool _syncingFromPlatform;
    bool _destroyed;
    bool _registered;
}

version (unittest)
{
    import cherry.ui.testing : TestPlatformWindow;
}

unittest
{
    // Defaults are pushed to the platform at creation; property changes
    // follow; show/close lifecycle raises onClosed.
    TestPlatformWindow platform;
    auto window = new Window((PlatformWindowHost host) {
        platform = new TestPlatformWindow(host);
        return cast(PlatformWindow) platform;
    });

    assert(platform.title == "Window");
    assert(platform.width == 600 && platform.height == 400);

    window.setValue(Window.titleProperty, Value("Hello"));
    assert(platform.title == "Hello");

    window.setValue(Window.widthProperty, Value(1024.0f));
    assert(platform.width == 1024 && platform.height == 400);

    window.show();
    assert(platform.visible);

    bool closedSeen;
    window.onClosed ~= (Window w) { closedSeen = (w is window); };
    window.close();
    assert(platform.destroyed);
    assert(closedSeen);
}

unittest
{
    // A subclass that registers no properties of its own still resolves the
    // base class's per-type metadata.  Without it the change callbacks are
    // never found, and a window that sets its own title in its constructor --
    // which is what a subclass is for -- would never show it.
    static class DerivedWindow : Window
    {
        this(scope PlatformWindow delegate(PlatformWindowHost) platformFactory)
        {
            super(platformFactory);
        }
    }

    TestPlatformWindow platform;
    auto window = new DerivedWindow((PlatformWindowHost host) {
        platform = new TestPlatformWindow(host);
        return cast(PlatformWindow) platform;
    });

    assert(rttiForName(typeid(window).name) is null,
           "the subclass registers nothing, so it has no RTTI of its own");

    assert(platform.width == 600 && platform.height == 400,
           "and still starts at Window's size, not at Element's unset default");

    window.setValue(Window.titleProperty, Value("Derived"));
    assert(platform.title == "Derived");

    window.setValue(Window.widthProperty, Value(1024.0f));
    assert(platform.width == 1024);
}

unittest
{
    // A platform-driven resize updates the properties without echoing the
    // size back to the platform.
    TestPlatformWindow platform;
    auto window = new Window((PlatformWindowHost host) {
        platform = new TestPlatformWindow(host);
        return cast(PlatformWindow) platform;
    });

    auto pushesBefore = platform.sizePushes;
    platform.host.onResized(1024, 768);

    assert(window.getValue(Window.widthProperty).get!float == 1024);
    assert(window.getValue(Window.heightProperty).get!float == 768);
    assert(platform.sizePushes == pushesBefore);   // no echo
}

unittest
{
    // Native mouse input becomes routed events raised on the window.
    TestPlatformWindow platform;
    auto window = new Window((PlatformWindowHost host) {
        platform = new TestPlatformWindow(host);
        return cast(PlatformWindow) platform;
    });

    MouseEventArgs seen;
    window.onMouseDown ~= (Element sender, RoutedEventArgs args) {
        seen = cast(MouseEventArgs) args;
    };

    platform.host.onMouseDown(MouseButton.left, 10, 20);

    assert(seen !is null);
    assert(seen.button == MouseButton.left);
    assert(seen.x == 10 && seen.y == 20);
    assert(seen.source is window);
    assert(!seen.handled);
}

unittest
{
    // A click lands on the deepest element under it and travels up from there,
    // so a handler on the window hears about it and learns where it started.
    //
    // Two bands stacked down the left of a container: the click at (30, 70) is
    // inside the container and inside the second band.
    //
    // Placed by margins rather than by a StackPanel, because nothing in
    // cherry.ui may import a control -- the banner in controls/stackpanel.d
    // explains what that rule is protecting, and a test import is still an
    // import.
    static class Band : Element
    {
        this(float top)
        {
            height = 50;
            margin = Thickness(0, top, 0, 0);
            verticalAlignment = VerticalAlignment.top;
        }
    }

    auto w = makeWindow();

    auto container = new Element;
    container.width = 100;
    container.height = 100;
    container.horizontalAlignment = HorizontalAlignment.left;
    container.verticalAlignment = VerticalAlignment.top;

    auto first = new Band(0);
    auto second = new Band(50);
    container.addChild(first);
    container.addChild(second);
    w.window.addChild(container);
    w.window.updateLayout();

    assert(second.arrangedRect == Rect(0, 50, 100, 50), "the bands do not overlap");

    Element[] route;
    MouseEventArgs seen;

    w.window.onMouseDown ~= (Element sender, RoutedEventArgs args) {
        route ~= sender;
        seen = cast(MouseEventArgs) args;
    };
    container.onMouseDown ~= (Element sender, RoutedEventArgs args) { route ~= sender; };
    second.onMouseDown ~= (Element sender, RoutedEventArgs args) { route ~= sender; };
    first.onMouseDown ~= (Element sender, RoutedEventArgs args) { route ~= sender; };

    w.platform.host.onMouseDown(MouseButton.left, 30, 70);

    assert(route == [cast(Element) second, container, w.window],
           "from the band up, and the sibling band never hears it");
    assert(seen.source is second, "and the args name where it started");
    assert(seen.getPosition(second) == Point(30, 20), "twenty down into the second band");
    assert(seen.getPosition(w.window) == Point(30, 70), "which is the client point");

    // Outside the panel there is only the window left to hit.
    route = null;
    w.platform.host.onMouseDown(MouseButton.left, 300, 200);
    assert(route == [cast(Element) w.window]);
}

version (unittest)
{
   /*
    * A box at a fixed place in its parent, and a log of what the pointer told
    * it.  Two of these side by side inside a third is the smallest tree that
    * has a shared ancestor to keep quiet about.
    */
    private class Zone : Element
    {
        string  name;
        string[]* log;

        this(string name, string[]* log, Rect place = Rect.init)
        {
            this.name = name;
            this.log = log;

            if (!place.empty)
            {
                width = place.width;
                height = place.height;
                margin = Thickness(place.x, place.y, 0, 0);
                horizontalAlignment = HorizontalAlignment.left;
                verticalAlignment = VerticalAlignment.top;
            }

            this.onMouseEnter ~= (Element sender, RoutedEventArgs args) {
                *this.log ~= "enter:" ~ this.name;
            };
            this.onMouseLeave ~= (Element sender, RoutedEventArgs args) {
                *this.log ~= "leave:" ~ this.name;
            };
        }
    }
}

unittest
{
    // Moving between two children of the same parent tells the two children
    // and leaves the parent alone -- the pointer never left it.
    string[] log;

    auto w = makeWindow();
    auto host = new Zone("host", &log, Rect(0, 0, 200, 100));
    auto left = new Zone("left", &log, Rect(0, 0, 100, 100));
    auto right = new Zone("right", &log, Rect(100, 0, 100, 100));
    host.addChild(left);
    host.addChild(right);
    w.window.addChild(host);
    w.window.updateLayout();

    // In from outside: everything from the window down learns about it, and
    // the outermost hears first.
    w.platform.host.onMouseMove(50, 50);
    assert(log == ["enter:host", "enter:left"]);
    assert(left.isMouseOver && host.isMouseOver && w.window.isMouseOver);

    // Across the boundary: one leaves, one arrives, and host says nothing.
    log = null;
    w.platform.host.onMouseMove(150, 50);
    assert(log == ["leave:left", "enter:right"]);
    assert(right.isMouseOver && host.isMouseOver);
    assert(!left.isMouseOver);

    // Within the same element there is nothing to report at all.
    log = null;
    w.platform.host.onMouseMove(160, 60);
    assert(log == []);

    // Out of the tree but still in the window: the deepest first on the way
    // out, and the window itself is still under the pointer.
    log = null;
    w.platform.host.onMouseMove(400, 300);
    assert(log == ["leave:right", "leave:host"]);
    assert(!right.isMouseOver && !host.isMouseOver);
    assert(w.window.isMouseOver, "the pointer is still inside the window");
}

unittest
{
    // A move handler reads the pointer's state as it is now, not as it was --
    // which is what the ordering inside handleMouseMove buys.
    string[] log;

    auto w = makeWindow();
    auto zone = new Zone("zone", &log, Rect(0, 0, 100, 100));
    w.window.addChild(zone);
    w.window.updateLayout();

    bool overWhenMoved;
    zone.onMouseMove ~= (Element sender, RoutedEventArgs args) {
        overWhenMoved = (cast(Element) sender).isMouseOver;
    };

    w.platform.host.onMouseMove(50, 50);
    assert(overWhenMoved, "enter had already run by the time move was raised");
}

unittest
{
    // The pointer leaving the window takes the whole chain with it, window
    // included -- there is nothing left for it to be over.
    string[] log;

    auto w = makeWindow();
    auto host = new Zone("host", &log, Rect(0, 0, 200, 100));
    auto inner = new Zone("inner", &log, Rect(0, 0, 100, 100));
    host.addChild(inner);
    w.window.addChild(host);
    w.window.updateLayout();

    w.platform.host.onMouseMove(50, 50);
    assert(inner.isMouseOver && host.isMouseOver && w.window.isMouseOver);

    log = null;
    w.platform.host.onMouseLeave();

    assert(log == ["leave:inner", "leave:host"], "deepest first, as on any other exit");
    assert(!inner.isMouseOver && !host.isMouseOver);
    assert(!w.window.isMouseOver, "and the window is not under the pointer either");

    // Leaving again with nothing over is not an error and reports nothing.
    log = null;
    w.platform.host.onMouseLeave();
    assert(log == []);

    // Coming back starts the chain over.
    w.platform.host.onMouseMove(50, 50);
    assert(log == ["enter:host", "enter:inner"]);
}

unittest
{
    // invalidate() forwards to the platform, and asks for all of it rather
    // than for a region.
    //
    // Counted against what was already there rather than from zero: laying a
    // brand new window out has its own reasons to ask for a repaint, and
    // whether that request has reached the platform by the time this line
    // runs is not this test's business.
    TestPlatformWindow platform;
    auto window = new Window((PlatformWindowHost host) {
        platform = new TestPlatformWindow(host);
        return cast(PlatformWindow) platform;
    });

    auto before = platform.invalidations;
    window.invalidate();

    assert(platform.invalidations == before + 1);
    assert(platform.invalidatedRegions[$ - 1].empty,
           "all of it, not a region: invalidate() names no rectangle");

    // A paint request on a handle-less fake is a no-op (no renderer).
    platform.host.onPaintRequested();
}

unittest
{
    // @event members surface through the class RTTI (for JUICE and tooling).
    import std.algorithm : canFind;

    assert(getRtti!Window.eventNames.canFind("onClosed"));
}

unittest
{
    // The application-level notifications reach the callbacks an application
    // wires up, and a window with nothing wired stays out of the way.
    TestPlatformWindow platform;
    auto window = new Window((PlatformWindowHost host) {
        platform = new TestPlatformWindow(host);
        return cast(PlatformWindow) platform;
    });

    assert(platform.host.onSessionEnding(SessionEndReason.logoff),
           "a window nobody listens through must not object to the session ending");

    bool[] activations;
    window.activatedCallback = (bool active) { activations ~= active; };

    platform.host.onActivationChanged(true);
    platform.host.onActivationChanged(false);
    assert(activations == [true, false]);

    SessionEndReason seen;
    window.sessionEndingCallback = (SessionEndReason reason) {
        seen = reason;
        return false;          // the application objects
    };

    assert(!platform.host.onSessionEnding(SessionEndReason.shutdown),
           "the application's refusal reaches the platform");
    assert(seen == SessionEndReason.shutdown);
}

unittest // a handler can refuse the close, whoever asked for it
{
    TestPlatformWindow platform;
    auto window = new Window((PlatformWindowHost host) {
        platform = new TestPlatformWindow(host);
        return cast(PlatformWindow) platform;
    });

    bool refuse = true;
    int asked;
    bool closed;

    window.onClosing ~= (Window w, ref bool cancel) { asked++; cancel = refuse; };
    window.onClosed ~= (Window w) { closed = true; };

    // The window's own close button takes the same route as close() does.
    platform.host.onCloseRequested();
    assert(asked == 1);
    assert(!platform.destroyed && !closed, "a refused close leaves the window alone");

    window.close();
    assert(asked == 2, "asking programmatically is asked all the same");
    assert(!platform.destroyed);

    refuse = false;
    window.close();
    assert(platform.destroyed && closed, "and it goes when nobody objects");
}

unittest // refusing and hiding is how a close button tucks a window away
{
    TestPlatformWindow platform;
    auto window = new Window((PlatformWindowHost host) {
        platform = new TestPlatformWindow(host);
        return cast(PlatformWindow) platform;
    });

    window.onClosing ~= (Window w, ref bool cancel) { cancel = true; w.hide(); };

    window.show();
    assert(platform.visible);

    platform.host.onCloseRequested();
    assert(!platform.visible, "the window went away...");
    assert(!platform.destroyed, "...without being destroyed");

    window.show();
    assert(platform.visible, "and it comes back, the same window as before");
}

unittest // any one handler is enough to refuse, and the later ones can tell
{
    TestPlatformWindow platform;
    auto window = new Window((PlatformWindowHost host) {
        platform = new TestPlatformWindow(host);
        return cast(PlatformWindow) platform;
    });

    bool lastSawTheRefusal;

    window.onClosing ~= (Window w, ref bool cancel) { };
    window.onClosing ~= (Window w, ref bool cancel) { cancel = true; };
    window.onClosing ~= (Window w, ref bool cancel) { lastSawTheRefusal = cancel; };

    window.close();

    assert(lastSawTheRefusal, "a handler sees that an earlier one objected");
    assert(!platform.destroyed);
}

unittest // shutting down goes past the refusal
{
    TestPlatformWindow platform;
    auto window = new Window((PlatformWindowHost host) {
        platform = new TestPlatformWindow(host);
        return cast(PlatformWindow) platform;
    });

    bool asked;
    window.onClosing ~= (Window w, ref bool cancel) { asked = true; cancel = true; };

    window.forceClose();

    assert(!asked, "a window does not get to veto the application shutting down");
    assert(platform.destroyed);
}

unittest // a closed window says so instead of working on a stale handle
{
    import std.exception : assertThrown;

    TestPlatformWindow platform;
    auto window = new Window((PlatformWindowHost host) {
        platform = new TestPlatformWindow(host);
        return cast(PlatformWindow) platform;
    });

    window.close();
    assert(platform.destroyed);

    assertThrown(window.show(), "showing a closed window must not silently do nothing");
    assertThrown(window.hide());

    // Closing what is already closed is simply nothing to do.
    window.close();
    window.forceClose();
}

version (unittest)
{
    import cherry.core.threading.testing : pumpUntilIdle;
    import cherry.ui.layout : LayoutManager;
    import cherry.ui.testing : makeWindow, withApplication;
}

unittest
{
    // A brand new window is laid out, so an element added to one can be asked
    // what size it came out at without waiting for the platform to say
    // anything.
    auto w = makeWindow();
    assert(w.window.isMeasureValid && w.window.isArrangeValid);

    auto child = new Element;
    w.window.addChild(child);
    w.window.updateLayout();

    assert(child.actualWidth == 600 && child.actualHeight == 400);
}

unittest
{
    // A resize from the platform is settled on the spot.  It arrives inside
    // the platform's own message handling and the frame showing the new size
    // is the next thing the platform will ask for, so there is nothing to be
    // gained by making it wait its turn.
    auto w = makeWindow();
    auto child = new Element;
    w.window.addChild(child);
    w.window.updateLayout();

    w.platform.host.onResized(1024, 768);

    assert(child.actualWidth == 1024 && child.actualHeight == 768,
           "no pump, and the tree has already taken the new shape");
    assert(w.window.width == 1024 && w.window.height == 768);
}

unittest
{
    // Setting the size from the application side queues a pass instead of
    // laying out inline: nothing is waiting on the answer, and whatever else
    // changes in this turn of the loop should be settled with it.
    withApplication((app, loop) {
        auto w = makeWindow();
        auto child = new Element;
        w.window.addChild(child);
        w.window.updateLayout();

        w.window.width = 800;

        assert(!w.window.isMeasureValid, "marked, and not yet answered");
        assert(child.actualWidth == 600, "still the size it was arranged at");
        assert(LayoutManager.forCurrentThread().isPassPending);

        pumpUntilIdle(app.dispatcher);

        assert(w.window.isMeasureValid && w.window.isArrangeValid);
        assert(child.actualWidth == 800);
    });
}

unittest
{
    // The whole round trip a real platform makes: the property pushes a size,
    // the platform answers with the resize, and the tree is laid out -- with
    // no pump, because the answer came back inside the assignment.
    auto w = makeWindow();
    auto child = new Element;
    w.window.addChild(child);
    w.window.updateLayout();

    w.platform.echoResize = true;
    auto pushesBefore = w.platform.sizePushes;

    w.window.width = 800;

    assert(child.actualWidth == 800);
    assert(w.platform.sizePushes == pushesBefore + 1,
           "the size that came back does not get pushed out again");
}

unittest
{
    // A resize to the size it already is costs nothing.  Windows sends plenty
    // of those, and the old code laid the whole tree out for every one.
    static class Counter : Element
    {
        int arranges;

        protected override Size arrangeOverride(Size finalSize)
        {
            arranges++;
            return super.arrangeOverride(finalSize);
        }
    }

    auto w = makeWindow();
    auto child = new Counter;
    w.window.addChild(child);
    w.window.updateLayout();

    auto before = child.arranges;
    w.platform.host.onResized(600, 400);

    assert(child.arranges == before, "same numbers, nothing to work out");
}

unittest
{
    // A margin on a window costs nothing.  It says where an element sits
    // inside a parent's slot, and a window has no parent to sit inside; left
    // to the generic code it would inset the content at the top left and push
    // the same amount off the bottom right.
    auto w = makeWindow();
    auto child = new Element;
    w.window.addChild(child);
    w.window.updateLayout();

    w.window.margin = Thickness(10);
    w.window.updateLayout();

    assert(w.window.actualWidth == 600 && w.window.actualHeight == 400);
    assert(child.arrangedRect == Rect(0, 0, 600, 400), "still the whole client area");
}

unittest
{
    // A minimum larger than the window constrains the content, not the native
    // frame: the tree is laid out at the minimum and overflows the client
    // area.  Pushing the minimum out to the OS, so the user cannot drag the
    // window below it, needs a platform seam that does not exist yet --
    // PlatformWindow knows setClientSize and nothing about limits.
    auto w = makeWindow();
    auto child = new Element;
    w.window.addChild(child);
    w.window.updateLayout();

    w.window.minWidth = 1000;
    w.window.updateLayout();

    assert(child.actualWidth == 1000, "laid out at the minimum");
    assert(w.platform.width == 600, "and the native window was left where it was");
}

version (unittest)
{
    import cherry.platform.render : FakeSolidPaint, RecordingContext;

   /// Draws its own bounds, so a test can read back where they landed.
    private static class RenderMarker : Element
    {
        protected override void onRender(DrawingContext context)
        {
            context.fillRectangle(Rect(0, 0, actualWidth, actualHeight), new FakeSolidPaint(Color.black));
        }
    }
}

unittest
{
    // A margin on a window costs nothing, drawing included.
    //
    // arrangeAsRoot passes a deliberately negative origin to cancel the
    // margin, and the arithmetic looks alarming: -m.left + m.left + 0 == 0.
    // Until now nothing rendered through arrangedRect, so a mistake there
    // would have been invisible to the whole suite.
    auto w = makeWindow();
    auto child = new RenderMarker;
    w.window.addChild(child);
    w.window.updateLayout();

    auto plain = new RecordingContext;
    w.window.renderSubtree(plain);
    assert(plain.entries[0].rect == Rect(0, 0, 600, 400));

    w.window.margin = Thickness(10);
    w.window.updateLayout();
    assert(w.window.arrangedRect == Rect(0, 0, 600, 400));

    auto margined = new RecordingContext;
    w.window.renderSubtree(margined);
    assert(margined.entries[0].rect == plain.entries[0].rect);
    assert(margined.depth == 0);
}

unittest
{
    // An edge this change makes visible for the first time, recorded so that
    // whoever meets it finds an explanation rather than a mystery.
    //
    // The margin cancellation does not cover an alignment other than stretch
    // combined with a size the client area cannot satisfy.  A minimum of 1000
    // in a 600-wide window aligned right is asked to sit 400 to the left of
    // the origin, so the tree draws off the left edge.  That is not the
    // window origin misbehaving -- it is alignment doing exactly what
    // alignment means, and arrangedRect has said so since it was written.
    // Only now does anything read it.
    auto w = makeWindow();
    auto child = new RenderMarker;
    w.window.addChild(child);
    w.window.updateLayout();

    w.window.minWidth = 1000;
    w.window.horizontalAlignment = HorizontalAlignment.right;
    w.window.updateLayout();

    assert(w.window.arrangedRect.x == -400);

    auto ctx = new RecordingContext;
    w.window.renderSubtree(ctx);
    assert(ctx.entries[0].rect == Rect(-400, 0, 1000, 400));
}
