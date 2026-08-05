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
 * Native input arrives through a private PlatformWindowHost adapter and is
 * raised as routed events on this element (hit-testing will pick a deeper
 * target once layout exists), so the platform plumbing does not leak into
 * the window's public API.
 */
class Window : Element
{
    shared static this()
    {
        PropertyMetadata titleMeta;
        titleMeta.defaultValue = Value("Window");
        titleMeta.onPropertyChanged ~= &titleChanged;
        titleProperty = Property.register("Title", getRtti!string(), getRtti!Window(), titleMeta);

        PropertyMetadata widthMeta;
        widthMeta.defaultValue = Value(800);
        widthMeta.onPropertyChanged ~= &sizeChanged;
        widthProperty = Property.register("Width", getRtti!int(), getRtti!Window(), widthMeta);

        PropertyMetadata heightMeta;
        heightMeta.defaultValue = Value(600);
        heightMeta.onPropertyChanged ~= &sizeChanged;
        heightProperty = Property.register("Height", getRtti!int(), getRtti!Window(), heightMeta);
    }

    static immutable(Property) titleProperty;
    static immutable(Property) widthProperty;
    static immutable(Property) heightProperty;

    @property string title() const
    {
        return getValue(titleProperty).get!string;
    }

    @property void title(string value)
    {
        setValue(titleProperty, Value(value));
    }

    @property int width() const
    {
        return getValue(widthProperty).get!int;
    }

    @property void width(int value)
    {
        setValue(widthProperty, Value(value));
    }

    @property int height() const
    {
        return getValue(heightProperty).get!int;
    }

    @property void height(int value)
    {
        setValue(heightProperty, Value(value));
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
        _platform.setClientSize(getValue(widthProperty).get!int,
                                getValue(heightProperty).get!int);

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
    * Schedules a repaint of the window content.
    */
    void invalidate()
    {
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
            this.outer.raiseEvent(new MouseEventArgs(mouseDownEvent, button, x, y));
        }

        void onMouseUp(MouseButton button, int x, int y)
        {
            this.outer.raiseEvent(new MouseEventArgs(mouseUpEvent, button, x, y));
        }

        void onMouseMove(int x, int y)
        {
            this.outer.raiseEvent(new MouseEventArgs(mouseMoveEvent, MouseButton.none, x, y));
        }
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
        _syncingFromPlatform = true;
        scope (exit) _syncingFromPlatform = false;

        setValue(widthProperty, Value(width));
        setValue(heightProperty, Value(height));
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

        window._platform.setClientSize(window.getValue(widthProperty).get!int,
                                       window.getValue(heightProperty).get!int);
    }

    PlatformWindow _platform;
    WindowRenderer _renderer;
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
    assert(platform.width == 800 && platform.height == 600);

    window.setValue(Window.titleProperty, Value("Hello"));
    assert(platform.title == "Hello");

    window.setValue(Window.widthProperty, Value(1024));
    assert(platform.width == 1024 && platform.height == 600);

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

    window.setValue(Window.titleProperty, Value("Derived"));
    assert(platform.title == "Derived");

    window.setValue(Window.widthProperty, Value(1024));
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

    assert(window.getValue(Window.widthProperty).get!int == 1024);
    assert(window.getValue(Window.heightProperty).get!int == 768);
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
    // invalidate() forwards to the platform.
    TestPlatformWindow platform;
    auto window = new Window((PlatformWindowHost host) {
        platform = new TestPlatformWindow(host);
        return cast(PlatformWindow) platform;
    });

    window.invalidate();
    assert(platform.invalidations == 1);

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
