module cherry.platform.win32.eventloop;

version (Windows):

import core.sys.windows.windows;
import core.time : Duration;

import cherry.platform.eventloop;

pragma(lib, "user32");

private enum UINT WM_CHERRY_WAKE = WM_APP + 1;
private enum UINT WM_CHERRY_QUIT = WM_APP + 2;
private enum UINT_PTR CHERRY_TIMER_ID = 1;

// Not all of these are in druntime's headers; declare what is missing.
private enum uint QS_EVENT_           = 0x2000;
private enum uint MWMO_INPUTAVAILABLE_ = 0x0004;
private enum uint USER_TIMER_MINIMUM_  = 0x0000000A;

/**
 * Win32 implementation of EventLoop: a message-only window receives posted
 * wake/quit messages, and run pumps the thread's message queue with
 * GetMessage/DispatchMessage.
 *
 * The loop must be created on the thread that will run it, because posted
 * messages are delivered to the queue of the thread that created the
 * window.
 *
 * TODO: wake/quit messages are intercepted in the run loop itself, so a
 * nested (modal) message pump would hand them to DefWindowProc and lose
 * them.  Move the handling into a real window procedure when modal loops
 * appear.
 */
final class Win32EventLoop : EventLoop
{
    this()
    {
        registerWindowClass();

        _threadId = GetCurrentThreadId();
        _hwnd = CreateWindowExW(0, windowClassName.ptr, null, 0,
                                0, 0, 0, 0,
                                HWND_MESSAGE, null, GetModuleHandleW(null), null);
        if (_hwnd is null)
            throw new Exception("Failed to create the event-loop message window.");
    }

    void run(scope void delegate() onWake)
    {
        assert(GetCurrentThreadId() == _threadId,
               "The event loop must run on the thread that created it.");

        onWake();

        MSG msg;
        while (GetMessageW(&msg, null, 0, 0) > 0)
        {
            if (msg.hwnd is _hwnd && msg.message == WM_CHERRY_WAKE)
            {
                onWake();
                continue;
            }

            if (msg.hwnd is _hwnd && msg.message == WM_CHERRY_QUIT)
                break;

            if (msg.hwnd is _hwnd && msg.message == WM_TIMER
                && msg.wParam == CHERRY_TIMER_ID)
            {
                KillTimer(_hwnd, CHERRY_TIMER_ID);   // one-shot
                onWake();
                continue;
            }

            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    void quit() shared
    {
        // PostMessage is thread-safe by the Win32 contract, so the handle
        // needs no further synchronization.
        PostMessageW(cast(HWND) _hwnd, WM_CHERRY_QUIT, 0, 0);
    }

    void requestWake() shared
    {
        PostMessageW(cast(HWND) _hwnd, WM_CHERRY_WAKE, 0, 0);
    }

    bool isInputPending()
    {
        return MsgWaitForMultipleObjectsEx(0, null, 0,
                   QS_INPUT | QS_EVENT_, MWMO_INPUTAVAILABLE_) == WAIT_OBJECT_0;
    }

    void requestWakeAfter(Duration delay)
    {
        // Owner-thread only.  SetTimer with a fixed id resets the timer, so
        // at most one deferred wake is outstanding; WM_TIMER is the
        // lowest-priority message, firing only after input has drained.
        auto ms = delay.total!"msecs";
        if (ms < USER_TIMER_MINIMUM_)
            ms = USER_TIMER_MINIMUM_;
        SetTimer(_hwnd, CHERRY_TIMER_ID, cast(UINT) ms, null);
    }

private:
    HWND  _hwnd;
    DWORD _threadId;

    static void registerWindowClass()
    {
        synchronized
        {
            if (s_classRegistered)
                return;

            WNDCLASSEXW wc;
            wc.cbSize = WNDCLASSEXW.sizeof;
            wc.lpfnWndProc = &DefWindowProcW;
            wc.hInstance = GetModuleHandleW(null);
            wc.lpszClassName = windowClassName.ptr;

            if (!RegisterClassExW(&wc))
                throw new Exception("Failed to register the event-loop window class.");

            s_classRegistered = true;
        }
    }
}

// String literals are zero-terminated, so .ptr is a valid LPCWSTR.
private immutable wstring windowClassName = "CherryEventLoop";
private __gshared bool s_classRegistered;

unittest
{
    import core.thread : Thread;

    auto loop = new Win32EventLoop;
    int wakes;

    // Other threads post through the shared view; run stays on the owner.
    auto remote = cast(shared) loop;

    auto worker = new Thread({
        foreach (i; 0 .. 3)
            remote.requestWake();
        remote.quit();
    });

    worker.start();
    loop.run({ wakes++; });
    worker.join();

    // Posted messages do not coalesce: one initial drain + exactly three.
    assert(wakes == 4);
}
