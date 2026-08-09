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
 * **Wake, quit and the deferred timer are handled in the window procedure and
 * not in the loop below**, and that is not tidiness.  Ours is not the only
 * message pump that will ever run on this thread: a MessageBox, a menu, a
 * modal drag all run their own, and they deliver messages with
 * DispatchMessage.  Anything this class recognised by inspecting messages
 * inside its own GetMessage loop would go to DefWindowProc in theirs and be
 * lost -- and a lost wake is not a missed frame but a permanent stall, because
 * whoever posted it is waiting for the work it was going to run and will not
 * post another.
 */
final class Win32EventLoop : EventLoop
{
    this()
    {
        registerWindowClass();

        _threadId = GetCurrentThreadId();

        // lpParam carries `this`; the window procedure stores it into
        // GWLP_USERDATA on WM_NCCREATE, the way Win32Window does.
        _hwnd = CreateWindowExW(0, windowClassName.ptr, null, 0,
                                0, 0, 0, 0,
                                HWND_MESSAGE, null, GetModuleHandleW(null),
                                cast(void*) this);
        if (_hwnd is null)
            throw new Exception("Failed to create the event-loop message window.");
    }

    void run(bool delegate() onWake)
    {
        assert(GetCurrentThreadId() == _threadId,
               "The event loop must run on the thread that created it.");

        // The handler and the flag that ends this loop are put where the window
        // procedure can reach them, and the ones belonging to the loop outside
        // are put back on the way out -- run is re-entrant, and a nested loop
        // ending must not end the one it was started from.
        bool leave;

        auto outerWake = _onWake;
        auto outerLeave = _leaveFlag;

        _onWake = onWake;
        _leaveFlag = &leave;

        scope (exit)
        {
            _onWake = outerWake;
            _leaveFlag = outerLeave;
        }

        deliverWake();
        rethrowEscaped();

        MSG msg;

        // The quit flag is read here rather than at the top, so that a quit
        // noticed while somebody else's pump was running still ends this loop
        // without waiting for another message to arrive.
        while (!leave && !_quitting && GetMessageW(&msg, null, 0, 0) > 0)
        {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);

            // Whatever the window procedure could not throw, this can.
            rethrowEscaped();
        }
    }

    void quit() shared
    {
        // PostMessage is thread-safe by the Win32 contract, so the handle needs
        // no further synchronization.  Nothing is decided here: the window
        // procedure raises the flag when this message is dispatched, which puts
        // it in line behind every wake already queued.
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
   /*
    * Runs the wake handler of whichever loop is innermost, recording what it
    * asked for rather than acting on it.
    *
    * nothrow because a window procedure is an extern(Windows) callback and a
    * D exception must not cross one.  What is caught is kept and rethrown by
    * run as soon as it is pumping again -- which may be after a modal dialog
    * closes, and is still better than losing it or corrupting the stack.
    */
    void deliverWake() nothrow
    {
        if (_onWake is null)
            return;

        try
        {
            if (!_onWake() && _leaveFlag !is null)
                *_leaveFlag = true;
        }
        catch (Throwable t)
        {
            _escaped = t;

            if (_leaveFlag !is null)
                *_leaveFlag = true;
        }
    }

    void rethrowEscaped()
    {
        if (auto t = _escaped)
        {
            _escaped = null;
            throw t;
        }
    }

    HWND  _hwnd;
    DWORD _threadId;

    // The innermost running loop's handler and the flag that ends it.  Saved
    // and restored around every run, so nesting works.
    bool delegate() _onWake;
    bool*           _leaveFlag;

    // What the wake handler threw where nothing could catch it.
    Throwable _escaped;

   /*
    * Set when the quit message is dispatched -- on this thread, in the order
    * it was posted, so every wake queued ahead of it has already been
    * delivered.  That ordering is the whole reason it is set here and not in
    * quit(): a flag raised by the posting thread would be seen before the
    * queue had drained, and the wake it overtook would be lost.
    *
    * Sticky, and never cleared: quit ends every loop, nested ones included.
    */
    bool _quitting;

    static void registerWindowClass()
    {
        synchronized
        {
            if (s_classRegistered)
                return;

            WNDCLASSEXW wc;
            wc.cbSize = WNDCLASSEXW.sizeof;
            wc.lpfnWndProc = &cherryLoopProc;
            wc.hInstance = GetModuleHandleW(null);
            wc.lpszClassName = windowClassName.ptr;

            if (!RegisterClassExW(&wc))
                throw new Exception("Failed to register the event-loop window class.");

            s_classRegistered = true;
        }
    }
}

/*
 * Where wake, quit and the deferred timer are really handled.
 *
 * Reached by DispatchMessage from whatever pump happens to be running -- ours,
 * a MessageBox's, a menu's -- which is the point: see the banner on the class.
 */
private extern (Windows) LRESULT cherryLoopProc(HWND hwnd, UINT message,
                                                WPARAM wParam, LPARAM lParam) nothrow
{
    if (message == WM_NCCREATE)
    {
        auto create = cast(CREATESTRUCTW*) lParam;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, cast(LONG_PTR) create.lpCreateParams);
    }

    auto loop = cast(Win32EventLoop) cast(void*) GetWindowLongPtrW(hwnd, GWLP_USERDATA);

    if (loop !is null)
    {
        switch (message)
        {
            case WM_CHERRY_WAKE:
                loop.deliverWake();
                return 0;

            case WM_CHERRY_QUIT:
                loop._quitting = true;
                return 0;

            case WM_TIMER:
                if (wParam == CHERRY_TIMER_ID)
                {
                    KillTimer(hwnd, CHERRY_TIMER_ID);   // one-shot
                    loop.deliverWake();
                    return 0;
                }
                break;

            default:
                break;
        }
    }

    return DefWindowProcW(hwnd, message, wParam, lParam);
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
    loop.run({ wakes++; return true; });
    worker.join();

    // Posted messages do not coalesce: one initial drain + exactly three.
    assert(wakes == 4);
}

unittest
{
    // A wake posted while somebody else's message pump is running still gets
    // delivered.
    //
    // This is the MessageBox case, and it is worth spelling out what went wrong
    // before the handling moved into the window procedure.  A modal dialog
    // pumps the thread's queue itself and delivers with DispatchMessage; a wake
    // recognised only inside this class's own GetMessage loop went to
    // DefWindowProc instead and vanished.  Nothing retried, because whoever
    // posted it was waiting for the work it carried and would not post another
    // -- so the render queue stopped for good and the window went dead to the
    // mouse until the application was restarted.
    auto loop = new Win32EventLoop;
    auto remote = cast(shared) loop;

    int wakes;
    bool pumpedForeign;

    loop.run({
        ++wakes;

        if (!pumpedForeign)
        {
            pumpedForeign = true;

            // Queue one, then drain the queue the way a modal dialog does.
            remote.requestWake();

            MSG msg;
            while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE))
            {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }

            // The wake has to have arrived by now, from inside that pump.
            assert(wakes == 2, "the foreign pump delivered it");

            remote.quit();
        }

        return true;
    });

    assert(wakes == 2);
}

unittest
{
    // Quit noticed during a foreign pump still ends the loop, without needing
    // another message to arrive first.
    auto loop = new Win32EventLoop;
    auto remote = cast(shared) loop;

    int wakes;

    loop.run({
        ++wakes;

        if (wakes == 1)
        {
            remote.quit();

            MSG msg;
            while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE))
            {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }

        return true;
    });

    assert(wakes == 1, "the quit was seen inside the foreign pump and run left at once");
}
