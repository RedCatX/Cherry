module cherry.platform;

public import cherry.platform.eventloop;

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
        import cherry.platform.win32.eventloop : Win32EventLoop;
        return new Win32EventLoop;
    }
    else
    {
        return new ManualEventLoop;
    }
}
