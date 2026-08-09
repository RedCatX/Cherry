module cherry.platform.window;

import cherry.platform.render : Rect;

/**
 * Why the desktop session is ending.
 */
enum SessionEndReason
{
    /// The user is logging off.
    logoff,
    /// The machine is shutting down or restarting.
    shutdown,
    /// The platform did not say, or said something we do not model.
    unknown
}

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

    /// The platform asks for the window content to be redrawn.
    void onPaintRequested();

   /**
    * The application this window belongs to gained or lost the foreground.
    *
    * Every top-level window of the application is told, so a host that
    * cares about the application as a whole should either listen through
    * one window or collapse the repeats itself.
    */
    void onActivationChanged(bool active);

   /**
    * The session is ending; returning false asks the platform to stop it.
    *
    * Asked of every top-level window, and any refusal is enough to stop the
    * session, so a window whose host does not care should simply agree.
    */
    bool onSessionEnding(SessionEndReason reason);

    /// Mouse input in client coordinates.
    void onMouseDown(MouseButton button, int x, int y);
    /// ditto
    void onMouseUp(MouseButton button, int x, int y);
    /// ditto
    void onMouseMove(int x, int y);

   /**
    * The pointer left the client area, and no position comes with it because
    * there is none to give -- it is somewhere else now.
    *
    * Without this the host cannot tell "the pointer stopped moving" from "the
    * pointer went away", and whatever it was over would stay over for good.  A
    * platform that cannot detect this must simply never call it; the host is
    * then no worse off than it would be with no notification at all.
    */
    void onMouseLeave();
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

   /**
    * Asks the platform to schedule a repaint of the whole client area
    * (onPaintRequested follows).
    *
    * Kept alongside the region form because "all of it" is not something the
    * framework can name as a rectangle: the window's own Width and Height are
    * what it asked for, which the platform may not yet have granted.
    */
    void invalidate();

   /**
    * Asks for a repaint of one region, in the same device-independent
    * coordinates the drawing model uses.
    *
    * The region is a lower bound on what will be repainted and never an upper
    * one: a platform may repaint more, and one that cannot express regions at
    * all answers this by invalidating everything.  An empty region asks for
    * nothing and must be honoured as such.
    */
    void invalidate(Rect region);

    @property int clientWidth();
    @property int clientHeight();

    /// The native handle (HWND on Windows) for future rendering backends.
    @property void* nativeHandle();
}
