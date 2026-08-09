module cherry.platform;

public import cherry.platform.dialog;
public import cherry.platform.entrypoint;
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
    import cherry.platform.win32.text : DWriteTextService, win32SystemTextFormat = systemTextFormat;
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

/**
 * Creates the text service for the current platform.  A platform-inspection
 * point like the other create* factories.
 *
 * Callers want `textService` below rather than this: laying text out costs a
 * font cache, and there is no reason for a thread to keep two of them.
 */
TextService createTextService()
{
    version (Windows)
    {
        return new DWriteTextService;
    }
    else
    {
        assert(false, "No text service implementation for this platform yet.");
    }
}

/**
 * The text service this thread measures with, made on first use.
 *
 * Per thread, like the layout manager and the dispatcher, and for the same
 * reason: a thread with a tree of its own lays that tree out by itself, and
 * nothing here is shared between two of them.  What is shared -- the font
 * cache -- is shared underneath, inside DirectWrite.
 *
 * Unlike the platform window and the renderer, this is reached rather than
 * handed down.  Measuring happens in the layout pass, where an element has a
 * parent and a size and no window: an element off the tree still has to be able
 * to ask how wide its text is, and threading a service down from a window it
 * may not have would make that impossible for no gain.
 */
@property TextService textService()
{
    if (s_textService is null)
        s_textService = createTextService();

    return s_textService;
}

/**
 * Puts a text service in place of the platform's own.
 *
 * For tests, which want metrics they chose rather than metrics the machine
 * happened to have, and for a host with no text backend at all.  Passing null
 * hands the slot back, and the next reader gets a fresh platform one.
 */
@property void textService(TextService service)
{
    s_textService = service;
}

/**
 * The font the system writes its own interface in.
 *
 * Separate from the service on purpose: it reads the platform's settings and
 * nothing more, with no COM and nothing lazily created, which is what lets a
 * control ask for it while registering its properties.  Going through the
 * service would mean building a font cache during module construction.
 *
 * On a platform with no answer this is the framework's own default, which is
 * a readable size in whatever the backend calls its default family.
 */
TextFormat systemTextFormat()
{
    version (Windows)
    {
        return win32SystemTextFormat();
    }
    else
    {
        return TextFormat.init;
    }
}

private TextService s_textService;

unittest
{
    // The slot fills itself, holds what it is given, and lets go when asked.
    // Restored on the way out whatever happens: it is thread-wide, and a test
    // that left a fake in it would be measuring for everybody else too.
    auto original = s_textService;
    scope (exit) s_textService = original;

    textService = null;
    auto platform = textService;
    assert(platform !is null);
    assert(textService is platform, "made once, not once per reader");

    auto fake = new FakeTextService;
    textService = fake;
    assert(textService is fake);

    textService = null;
    assert(textService !is null && textService !is fake,
           "handing the slot back gets the platform's own again");
}
