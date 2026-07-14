module cherry.platform.window;

/**
 * Normalized mouse button identity shared by every platform backend.
 */
enum MouseButton
{
    none,
    left,
    middle,
    right
}

/**
 * Receives normalized notifications from a platform window.  Implemented by
 * the framework's Window; platform code is a dumb driver that only reports
 * what happened -- all policy (closing behavior, routing, hit-testing)
 * lives above this interface.
 */
interface PlatformWindowHost
{
    /// The user asked to close the window (e.g. the X button).  The host
    /// decides whether to actually close.
    void onCloseRequested();

    /// The native window has been destroyed.
    void onDestroyed();

    /// The client area changed size.
    void onResized(int width, int height);

    /// Mouse input in client coordinates.
    void onMouseDown(MouseButton button, int x, int y);
    /// ditto
    void onMouseUp(MouseButton button, int x, int y);
    /// ditto
    void onMouseMove(int x, int y);
}

/**
 * A native top-level window surface -- the platform seam for Window.
 * Implementations must be created and used on the thread that runs the
 * dispatcher's event loop.
 */
interface PlatformWindow
{
    /// Makes the window visible / hides it.
    void show();
    /// ditto
    void hide();

    /// Destroys the native window; onDestroyed is reported to the host.
    void close();

    /// Sets the window caption.
    void setTitle(string title);

    /// Requests a client-area size.
    void setClientSize(int width, int height);

    @property int clientWidth();
    @property int clientHeight();

    /// The native handle (HWND on Windows) for future rendering backends.
    @property void* nativeHandle();
}
