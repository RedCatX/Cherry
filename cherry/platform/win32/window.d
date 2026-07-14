module cherry.platform.win32.window;

version (Windows):

import core.stdc.stdio : fprintf, stderr;
import core.sys.windows.windows;
import std.utf : toUTF16z;

import cherry.platform.window;

pragma(lib, "user32");

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
                notify({ _host.onMouseMove(mouseX(lParam), mouseY(lParam)); });
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
