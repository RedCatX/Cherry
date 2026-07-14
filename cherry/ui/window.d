module cherry.ui.window;

import cherry.core.multicast;
import cherry.core.property;
import cherry.core.rtti;
import cherry.core.value;
import cherry.platform;
import cherry.ui.element;
import cherry.ui.event;
import cherry.ui.input;

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

   /**
    * Raised after the native window has been destroyed.  A plain Multicast
    * event: window lifetime is not a tree concern, so it does not route.
    */
    Multicast!(void delegate(Window)) onClosed;

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
        _platform = platformFactory(new PlatformHost);

        // Push the effective (default or preset) values to the platform.
        _platform.setTitle(getValue(titleProperty).get!string);
        _platform.setClientSize(getValue(widthProperty).get!int,
                                getValue(heightProperty).get!int);
    }

   /**
    * Makes the window visible.
    */
    void show()
    {
        _platform.show();
    }

   /**
    * Destroys the native window; onClosed is raised afterwards.
    */
    void close()
    {
        _platform.close();
    }

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
        if (!onClosed.empty)
            onClosed(this);
    }

    void handleResized(int width, int height)
    {
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
        if (window is null || window._syncingFromPlatform || window._platform is null)
            return;

        window._platform.setTitle(newValue.get!string);
    }

    static void sizeChanged(const(Object) obj, const(Value) oldValue, const(Value) newValue)
    {
        auto window = cast(Window) cast() obj;
        if (window is null || window._syncingFromPlatform || window._platform is null)
            return;

        window._platform.setClientSize(window.getValue(widthProperty).get!int,
                                       window.getValue(heightProperty).get!int);
    }

    PlatformWindow _platform;
    bool _syncingFromPlatform;
}

version (unittest)
{
   /*
    * A fake platform window: records every push from the framework and lets
    * tests inject host notifications as if they came from the OS.
    */
    private final class TestPlatformWindow : PlatformWindow
    {
        PlatformWindowHost host;
        string title;
        int width;
        int height;
        bool visible;
        bool destroyed;
        int sizePushes;

        this(PlatformWindowHost host)
        {
            this.host = host;
        }

        void show() { visible = true; }
        void hide() { visible = false; }

        void close()
        {
            destroyed = true;
            host.onDestroyed();   // mirrors WM_DESTROY
        }

        void setTitle(string value) { title = value; }

        void setClientSize(int w, int h)
        {
            width = w;
            height = h;
            sizePushes++;
        }

        @property int clientWidth() { return width; }
        @property int clientHeight() { return height; }
        @property void* nativeHandle() { return null; }
    }
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
