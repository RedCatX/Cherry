module cherry.ui.testing;

/**
 * Helpers shared by the unit tests of the modules in this package.  The whole
 * module is behind version(unittest), so importing it from production code
 * costs nothing.
 */

version (unittest):

import cherry.core.threading;
import cherry.core.threading.testing : releaseAmbientDispatcher;
import cherry.platform;
import cherry.ui.application;
import cherry.ui.window;

/**
 * A fake platform window: records every push from the framework and lets a
 * test inject host notifications as if they had come from the OS.
 */
final class TestPlatformWindow : PlatformWindow
{
    PlatformWindowHost host;
    string title;
    int width;
    int height;
    bool visible;
    bool destroyed;
    int sizePushes;
    int invalidations;

   /**
    * Closes the loop the real platform closes: a size pushed to this fake
    * comes back as the resize notification the OS would have sent.
    *
    * Off by default, because most tests want to watch what the window pushes
    * without the answer coming back and changing what they are watching.
    */
    bool echoResize;

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

   /**
    * Every repaint asked for, in order.  A request that named no region
    * records an empty rectangle rather than the client area, so that a
    * regression where the framework starts asking for everything when it
    * should have asked for a region is visible instead of blending in.
    */
    Rect[] invalidatedRegions;

    void invalidate()
    {
        invalidations++;
        invalidatedRegions ~= Rect.init;
    }

    void invalidate(Rect region)
    {
        invalidations++;
        invalidatedRegions ~= region;
    }

    /// The union of everything asked for, which is what most tests want.
    @property Rect invalidatedUnion()
    {
        Rect all;
        foreach (region; invalidatedRegions)
            all = all.unite(region);
        return all;
    }

   /**
    * How many times the mouse was captured and released, and whether it is
    * held now.
    *
    * Counted rather than merely flagged, because the failure worth catching is
    * a capture taken twice or released on a path that already released it --
    * neither of which a boolean would show.
    */
    int captures;
    /// ditto
    int releases;
    /// ditto
    bool mouseCaptured;

    void captureMouse()
    {
        captures++;
        mouseCaptured = true;
    }

    void releaseMouseCapture()
    {
        releases++;
        mouseCaptured = false;
    }

    void setClientSize(int w, int h)
    {
        width = w;
        height = h;
        sizePushes++;

        if (echoResize)
            host.onResized(w, h);
    }

    @property int clientWidth() { return width; }
    @property int clientHeight() { return height; }
    @property void* nativeHandle() { return null; }
}

/**
 * A window and the fake platform underneath it.  Subscripting through to the
 * window means a test can treat it as one: `w.show()` drives the window,
 * `w.platform.visible` checks what the platform was told.
 */
struct TestWindow
{
    Window window;
    TestPlatformWindow platform;

    alias window this;
}

/**
 * Builds a window on a fake platform.
 */
TestWindow makeWindow()
{
    TestPlatformWindow fake;

    auto window = new Window((PlatformWindowHost host) {
        fake = new TestPlatformWindow(host);
        return cast(PlatformWindow) fake;
    });

    return TestWindow(window, fake);
}

/**
 * Runs body with an application on a dispatcher of its own, releasing both
 * afterwards whatever happens.
 *
 * Both are process-wide singletons, so a test that left one behind would take
 * the next one down with it: shutdown() clears the application and hands the
 * dispatcher's thread-local slot back.
 */
void withApplication(scope void delegate(UIApplication app, ManualEventLoop loop) body)
{
    releaseAmbientDispatcher();

    auto loop = new ManualEventLoop;
    auto dispatcher = new Dispatcher(loop);

    auto app = new UIApplication;
    scope (exit) app.shutdown();

    body(app, loop);
}
