module cherry.platform.win32.window;

version (Windows):

import core.stdc.stdio : fprintf, stderr;
import core.sys.windows.windows;
import std.utf : toUTF16z;

import cherry.platform.render : Rect;
import cherry.platform.window;

pragma(lib, "user32");

// Not in druntime's headers.
private enum LPARAM ENDSESSION_LOGOFF_ = 0x80000000;

/**
 * Win32 implementation of PlatformWindow: a real top-level window whose
 * window procedure translates WM_* messages into the normalized
 * PlatformWindowHost notifications.
 */
final class Win32Window : PlatformWindow
{
    this(PlatformWindowHost host)
    in {
        assert(host !is null);
    }
    do {
        _host = host;
        registerWindowClass();

        // lpParam carries `this`; the window procedure stores it into
        // GWLP_USERDATA on WM_NCCREATE and dispatches to handleMessage.
        _hwnd = CreateWindowExW(0, windowClassName.ptr, ""w.ptr,
                                WS_OVERLAPPEDWINDOW,
                                CW_USEDEFAULT, CW_USEDEFAULT,
                                CW_USEDEFAULT, CW_USEDEFAULT,
                                null, null, GetModuleHandleW(null),
                                cast(void*) this);
        if (_hwnd is null)
            throw new Exception("Failed to create the native window.");
    }

    void show()
    {
        ShowWindow(_hwnd, SW_SHOWNORMAL);
        UpdateWindow(_hwnd);
    }

    void hide()
    {
        ShowWindow(_hwnd, SW_HIDE);
    }

    void close()
    {
        DestroyWindow(_hwnd);
    }

    void setTitle(string title)
    {
        SetWindowTextW(_hwnd, title.toUTF16z());
    }

    void invalidate()
    {
        InvalidateRect(_hwnd, null, FALSE);
    }

    void invalidate(Rect region)
    {
        // An empty region asks for nothing, and a null RECT* is what
        // InvalidateRect reads as "the whole window" -- arriving there by
        // accident is exactly what this stops.
        if (region.empty)
            return;

        // Outward to whole pixels.  A rectangle covering half a pixel needs
        // that pixel repainted, and rounding outward is the only rule that
        // cannot leave a seam along an edge.  RECT's right and bottom are
        // exclusive, which is what ceil gives.
        //
        // The framework's coordinates are device-independent; this process is
        // DPI-unaware, so a device-independent pixel is a pixel.  The day that
        // stops being true, the scale belongs here and nowhere else: this is
        // the one place the two spaces meet.
        import std.math : ceil, floor;

        auto rect = RECT(cast(int) floor(region.x),
                         cast(int) floor(region.y),
                         cast(int) ceil(region.right),
                         cast(int) ceil(region.bottom));

        InvalidateRect(_hwnd, &rect, FALSE);
    }

    void captureMouse()
    {
        SetCapture(_hwnd);
    }

    void releaseMouseCapture()
    {
        // Only if it is still ours.  ReleaseCapture is process-wide, so calling
        // it while somebody else holds the mouse would take it from them -- and
        // the usual reason we no longer have it is that WM_CAPTURECHANGED has
        // already been and gone.
        if (GetCapture() is _hwnd)
            ReleaseCapture();
    }

    void setClientSize(int width, int height)
    {
        auto rect = RECT(0, 0, width, height);
        AdjustWindowRectEx(&rect, WS_OVERLAPPEDWINDOW, FALSE, 0);
        SetWindowPos(_hwnd, null, 0, 0,
                     rect.right - rect.left, rect.bottom - rect.top,
                     SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    @property int clientWidth()
    {
        RECT rect;
        GetClientRect(_hwnd, &rect);
        return rect.right;
    }

    @property int clientHeight()
    {
        RECT rect;
        GetClientRect(_hwnd, &rect);
        return rect.bottom;
    }

    @property void* nativeHandle()
    {
        return _hwnd;
    }

private:
    LRESULT handleMessage(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) nothrow
    {
        switch (message)
        {
            case WM_CLOSE:
                notify({ _host.onCloseRequested(); });
                return 0;

            case WM_DESTROY:
                notify({ _host.onDestroyed(); });
                return 0;

            case WM_SIZE:
                notify({ _host.onResized(LOWORD(lParam), HIWORD(lParam)); });
                return 0;

            case WM_ACTIVATEAPP:
                notify({ _host.onActivationChanged(wParam != 0); });
                return 0;

            case WM_QUERYENDSESSION:
            {
                // A host that fails to answer is taken to agree: a broken
                // handler must not be what keeps the machine from shutting
                // down.
                BOOL allow = TRUE;
                notify({
                    allow = _host.onSessionEnding(toSessionEndReason(lParam)) ? TRUE : FALSE;
                });

                return allow;
            }

            case WM_PAINT:
            {
                // BeginPaint/EndPaint validate the dirty region; Direct2D
                // presents through its own surface.
                PAINTSTRUCT ps;
                BeginPaint(hwnd, &ps);
                notify({ _host.onPaintRequested(); });
                EndPaint(hwnd, &ps);
                return 0;
            }

            case WM_LBUTTONDOWN:
                notify({ _host.onMouseDown(MouseButton.left, mouseX(lParam), mouseY(lParam)); });
                return 0;

            case WM_MBUTTONDOWN:
                notify({ _host.onMouseDown(MouseButton.middle, mouseX(lParam), mouseY(lParam)); });
                return 0;

            case WM_RBUTTONDOWN:
                notify({ _host.onMouseDown(MouseButton.right, mouseX(lParam), mouseY(lParam)); });
                return 0;

            case WM_LBUTTONUP:
                notify({ _host.onMouseUp(MouseButton.left, mouseX(lParam), mouseY(lParam)); });
                return 0;

            case WM_MBUTTONUP:
                notify({ _host.onMouseUp(MouseButton.middle, mouseX(lParam), mouseY(lParam)); });
                return 0;

            case WM_RBUTTONUP:
                notify({ _host.onMouseUp(MouseButton.right, mouseX(lParam), mouseY(lParam)); });
                return 0;

            case WM_MOUSEMOVE:
                trackMouseLeave(hwnd);
                notify({ _host.onMouseMove(mouseX(lParam), mouseY(lParam)); });
                return 0;

            case WM_CAPTURECHANGED:
                // Sent whoever took it away, including ourselves -- which is
                // what makes it the one place the host can trust.
                notify({ _host.onMouseCaptureLost(); });
                return 0;

            case WM_MOUSELEAVE:
                // The subscription is spent; the next move buys another.
                _trackingLeave = false;
                notify({ _host.onMouseLeave(); });
                return 0;

            default:
                return DefWindowProcW(hwnd, message, wParam, lParam);
        }
    }

   /*
    * D exceptions must not cross the extern(Windows) callback boundary.
    * TODO: forward to a dispatcher-level unhandled-exception hook instead
    * of printing, once one exists.
    */
    void notify(scope void delegate() callback) nothrow
    {
        try
        {
            callback();
        }
        catch (Throwable t)
        {
            try
                fprintf(stderr, "Unhandled exception in a window callback: %.*s\n",
                        cast(int) t.msg.length, t.msg.ptr);
            catch (Throwable)
            {
            }
        }
    }

    static SessionEndReason toSessionEndReason(LPARAM lParam) pure nothrow @nogc
    {
        if (lParam & ENDSESSION_LOGOFF_)
            return SessionEndReason.logoff;

        // Zero means the machine itself is going down; anything else is a
        // flag combination we do not model.
        return lParam == 0 ? SessionEndReason.shutdown : SessionEndReason.unknown;
    }

   /*
    * Asks to be told once when the pointer leaves the client area.
    *
    * Windows has no such message until it is asked for, and the subscription
    * is spent the moment it fires -- so it has to be renewed, and the natural
    * place is the movement that proves the pointer is here.  The flag is what
    * keeps that from being a call on every WM_MOUSEMOVE.
    *
    * A failure is left alone: the pointer would then stay logically inside the
    * window until it came back, which is wrong but quiet, and there is nothing
    * better to do about it from here.
    */
    void trackMouseLeave(HWND hwnd) nothrow
    {
        if (_trackingLeave)
            return;

        TRACKMOUSEEVENT tracking;
        tracking.cbSize = TRACKMOUSEEVENT.sizeof;
        tracking.dwFlags = TME_LEAVE;
        tracking.hwndTrack = hwnd;

        _trackingLeave = TrackMouseEvent(&tracking) != FALSE;
    }

    static int mouseX(LPARAM lParam) pure nothrow @nogc
    {
        return cast(short) LOWORD(lParam);
    }

    static int mouseY(LPARAM lParam) pure nothrow @nogc
    {
        return cast(short) HIWORD(lParam);
    }

    static void registerWindowClass()
    {
        synchronized
        {
            if (s_classRegistered)
                return;

            WNDCLASSEXW wc;
            wc.cbSize = WNDCLASSEXW.sizeof;
            wc.style = CS_HREDRAW | CS_VREDRAW;
            wc.lpfnWndProc = &cherryWindowProc;
            wc.hInstance = GetModuleHandleW(null);
            wc.hCursor = LoadCursorW(null, cast(const(wchar)*) 32512); // IDC_ARROW
            wc.hbrBackground = cast(HBRUSH)(COLOR_WINDOW + 1);
            wc.lpszClassName = windowClassName.ptr;

            if (!RegisterClassExW(&wc))
                throw new Exception("Failed to register the window class.");

            s_classRegistered = true;
        }
    }

    PlatformWindowHost _host;
    HWND               _hwnd;
    // Whether a WM_MOUSELEAVE is still owed to us.  TME_LEAVE is a one-shot
    // subscription, so this is what says whether one is outstanding.
    bool               _trackingLeave;
}

private extern (Windows) LRESULT cherryWindowProc(HWND hwnd, UINT message,
                                                  WPARAM wParam, LPARAM lParam) nothrow
{
    if (message == WM_NCCREATE)
    {
        auto create = cast(CREATESTRUCTW*) lParam;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, cast(LONG_PTR) create.lpCreateParams);
    }

    auto window = cast(Win32Window) cast(void*) GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (window is null)
        return DefWindowProcW(hwnd, message, wParam, lParam);

    return window.handleMessage(hwnd, message, wParam, lParam);
}

// String literals are zero-terminated, so .ptr is a valid LPCWSTR.
private immutable wstring windowClassName = "CherryWindow";
private __gshared bool s_classRegistered;
