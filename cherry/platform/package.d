module cherry.platform;

public import cherry.platform.dialog;
public import cherry.platform.eventloop;
public import cherry.platform.render;
public import cherry.platform.window;

// The backend modules are imported here, at module level, rather than inside
// the factory bodies below.  A dependency scanner (rdmd, dub) only sees the
// module-level imports of an imported module -- the function bodies of a
// non-root module are never analysed, so an import written inside one stays
// invisible, the backend never gets compiled, and the build fails at link
// time with unresolved externals.
version (Windows)
{
    import cherry.platform.win32.eventloop : Win32EventLoop;
    import cherry.platform.win32.render : D2DWindowRenderer;
    import cherry.platform.win32.window : Win32Window;
}

/**
 * Creates the native event loop for the current platform, falling back to
 * the portable ManualEventLoop where no native implementation exists yet.
 *
 * This function and the implementation modules under cherry/platform are
 * the only places allowed to inspect the platform; framework code above
 * this package stays platform-agnostic.
 */
EventLoop createPlatformEventLoop()
{
    version (Windows)
    {
        return new Win32EventLoop;
    }
    else
    {
        return new ManualEventLoop;
    }
}

/**
 * Creates a native top-level window driven by the given host.  Like
 * createPlatformEventLoop, this is a platform-inspection point; framework
 * code above cherry.platform stays platform-agnostic.
 */
PlatformWindow createPlatformWindow(PlatformWindowHost host)
{
    version (Windows)
    {
        return new Win32Window(host);
    }
    else
    {
        assert(false, "No platform window implementation for this platform yet.");
    }
}

/**
 * Creates a renderer for a native window.  A platform-inspection point like
 * the other create* factories.
 */
WindowRenderer createWindowRenderer(PlatformWindow window)
in {
    assert(window !is null);
    assert(window.nativeHandle !is null);
}
do {
    version (Windows)
    {
        return new D2DWindowRenderer(window.nativeHandle);
    }
    else
    {
        assert(false, "No renderer implementation for this platform yet.");
    }
}
