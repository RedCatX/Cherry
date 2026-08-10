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

// Bit 30 of the lParam of a key message: the key was already down, so this one
// came from the auto-repeat rather than from the user pressing anything.
private enum LPARAM KEY_WAS_DOWN = 1 << 30;

// The high bit of GetKeyState's answer is "held right now"; the low bit is the
// toggle state of Caps Lock and friends, which is a different question.
private enum ushort KEY_HELD = 0x8000;

/**
 * Which Key each Windows virtual-key code means, or Key.unknown for the ones
 * this framework does not model.
 *
 * Built at compile time, so this file needs no module constructor -- and the
 * table is in the binary's read-only data rather than being filled in at start
 * up.  The reverse direction is deliberately absent: nothing needs to turn a
 * Key back into a VK, and a table that existed would have to be kept honest.
 */
private immutable Key[256] keyFromVirtual = buildKeyTable();

private Key[256] buildKeyTable() pure nothrow
{
    Key[256] table;

    // The letters and the digit row are contiguous in both, and the VK codes
    // are the ASCII ones -- the single place where Windows is kind.
    foreach (i; 0 .. 26)
        table['A' + i] = cast(Key)(Key.a + i);

    foreach (i; 0 .. 10)
        table['0' + i] = cast(Key)(Key.d0 + i);

    foreach (i; 0 .. 10)
        table[0x60 + i] = cast(Key)(Key.numPad0 + i);   // VK_NUMPAD0

    foreach (i; 0 .. 24)
        table[0x70 + i] = cast(Key)(Key.f1 + i);        // VK_F1

    table[0x6A] = Key.multiply;
    table[0x6B] = Key.add;
    table[0x6D] = Key.subtract;
    table[0x6E] = Key.decimal;
    table[0x6F] = Key.divide;

    table[0x08] = Key.back;
    table[0x09] = Key.tab;
    table[0x0D] = Key.enter;
    table[0x1B] = Key.escape;
    table[0x20] = Key.space;

    table[0x21] = Key.pageUp;
    table[0x22] = Key.pageDown;
    table[0x23] = Key.end;
    table[0x24] = Key.home;
    table[0x25] = Key.left;
    table[0x26] = Key.up;
    table[0x27] = Key.right;
    table[0x28] = Key.down;
    table[0x2D] = Key.insert;
    table[0x2E] = Key.delete_;

    table[0x14] = Key.capsLock;
    table[0x90] = Key.numLock;
    table[0x91] = Key.scrollLock;
    table[0x2C] = Key.printScreen;
    table[0x13] = Key.pause;

    table[0x10] = Key.shift;
    table[0x11] = Key.control;
    table[0x12] = Key.alt;
    table[0x5B] = Key.leftWindows;
    table[0x5C] = Key.rightWindows;
    table[0x5D] = Key.apps;

    // Named for where they sit on a US layout, which is all a position can be
    // named for -- what they type is the layout's business and arrives as text.
    table[0xBA] = Key.oemSemicolon;
    table[0xBB] = Key.oemPlus;
    table[0xBC] = Key.oemComma;
    table[0xBD] = Key.oemMinus;
    table[0xBE] = Key.oemPeriod;
    table[0xBF] = Key.oemQuestion;
    table[0xC0] = Key.oemTilde;
    table[0xDB] = Key.oemOpenBrackets;
    table[0xDC] = Key.oemPipe;
    table[0xDD] = Key.oemCloseBrackets;
    table[0xDE] = Key.oemQuotes;
    table[0xE2] = Key.oemBackslash;

    return table;
}

/// The key a virtual-key code names, or Key.unknown.
private Key toKey(WPARAM virtualKey) nothrow @nogc
{
    return virtualKey < keyFromVirtual.length ? keyFromVirtual[cast(size_t) virtualKey] : Key.unknown;
}

/**
 * Turns the stream of WM_CHAR code units into whole characters of text.
 *
 * Two things are sorted out here.  Windows sends UTF-16 code units, so anything
 * outside the basic plane -- an emoji, most historic scripts -- arrives as two
 * messages that are half a character each; the first is held and the pair is
 * joined when the second lands.  A lead surrogate left dangling by a tail that
 * never came is dropped when the next unit arrives, which is the only answer
 * available: there is no character to report and no way to ask for the rest.
 *
 * And WM_CHAR delivers the control codes too -- Escape is 0x1B here, Enter is
 * 0x0D, Backspace 0x08 -- because they were characters in 1984.  They are not
 * text, they already arrived as keys, and they are dropped.  Tab is dropped
 * with them for the same reason: every control wants it as a key, and a control
 * that also wants it as text can put one in itself.
 *
 * A struct rather than a method on the window so that it can be tested without
 * one -- the state is one code unit, and a window is a poor thing to need in
 * order to check a surrogate pair.
 */
private struct TextAssembler
{
   /**
    * The text this unit completes, or null when it completes none.
    */
    string take(wchar unit) nothrow
    {
        // 0xD800-0xDBFF leads a pair, 0xDC00-0xDFFF finishes one.
        if (unit >= 0xD800 && unit <= 0xDBFF)
        {
            _lead = unit;
            return null;
        }

        dchar character = unit;

        if (unit >= 0xDC00 && unit <= 0xDFFF)
        {
            if (_lead == 0)
                return null;   // a tail with no head: nothing to make of it

            character = 0x10000 + ((_lead - 0xD800) << 10) + (unit - 0xDC00);
            _lead = 0;
        }
        else
        {
            _lead = 0;
        }

        if (character < 0x20 || character == 0x7F)
            return null;

        try
        {
            import std.conv : to;
            return to!string(character);
        }
        catch (Throwable)
        {
            return null;
        }
    }

private:
    wchar _lead;
}

unittest
{
    // The letters and digits are where the table says, and everything it does
    // not name is unknown rather than something invented.
    assert(toKey('A') == Key.a && toKey('Z') == Key.z);
    assert(toKey('0') == Key.d0 && toKey('9') == Key.d9);
    assert(toKey(0x60) == Key.numPad0 && toKey(0x69) == Key.numPad9);
    assert(toKey(0x70) == Key.f1 && toKey(0x87) == Key.f24);
    assert(toKey(0x0D) == Key.enter);
    assert(toKey(0x1B) == Key.escape);
    assert(toKey(0x09) == Key.tab);
    assert(toKey(0x20) == Key.space);
    assert(toKey(0x2E) == Key.delete_);
    assert(toKey(0x25) == Key.left && toKey(0x28) == Key.down);
    assert(toKey(0x10) == Key.shift);

    assert(toKey(0x07) == Key.unknown, "a code the table does not name");
    assert(toKey(0xFF) == Key.unknown);
    assert(toKey(4242) == Key.unknown, "and one that is not a code at all");
}

unittest
{
    TextAssembler assembler;

    // The ordinary case: one unit, one character.
    assert(assembler.take('a') == "a");
    assert(assembler.take(cast(wchar) 0x00E9) == "é");

    // A character outside the basic plane arrives in two messages and is
    // reported once, whole.  U+1F600 is 0xD83D 0xDE00.
    assert(assembler.take(cast(wchar) 0xD83D) is null, "half a character is not text");
    assert(assembler.take(cast(wchar) 0xDE00) == "\U0001F600");

    // A lead nobody finished does not corrupt what comes after it.
    assert(assembler.take(cast(wchar) 0xD83D) is null);
    assert(assembler.take('x') == "x");

    // A tail with no lead is dropped rather than turned into nonsense.
    assert(assembler.take(cast(wchar) 0xDE00) is null);
    assert(assembler.take('y') == "y");

    // The control codes are keys, not text -- they have already been reported
    // as key events by the time they arrive here.
    assert(assembler.take(cast(wchar) 0x1B) is null, "escape");
    assert(assembler.take(cast(wchar) 0x0D) is null, "enter");
    assert(assembler.take(cast(wchar) 0x08) is null, "backspace");
    assert(assembler.take(cast(wchar) 0x09) is null, "tab");
    assert(assembler.take(cast(wchar) 0x7F) is null, "delete");
    assert(assembler.take(' ') == " ", "but a space is a character somebody typed");
}

/*
 * Which modifiers are held at this moment.
 *
 * Asked of Windows rather than tracked, because tracking them means being told
 * about every press and release -- and the releases that happen while another
 * window has the keyboard are exactly the ones that never arrive.  A Shift
 * released during an Alt+Tab would otherwise stay down forever.
 */
private ModifierKeys currentModifiers() nothrow @nogc
{
    int held;

    if (GetKeyState(VK_SHIFT) & KEY_HELD)   held |= ModifierKeys.shift;
    if (GetKeyState(VK_CONTROL) & KEY_HELD) held |= ModifierKeys.control;
    if (GetKeyState(VK_MENU) & KEY_HELD)    held |= ModifierKeys.alt;

    if ((GetKeyState(VK_LWIN) & KEY_HELD) || (GetKeyState(VK_RWIN) & KEY_HELD))
        held |= ModifierKeys.windows;

    return cast(ModifierKeys) held;
}

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

            case WM_KEYDOWN:
            case WM_SYSKEYDOWN:
            {
                bool claimed;
                notify({
                    claimed = _host.onKeyDown(toKey(wParam), currentModifiers(),
                                              (lParam & KEY_WAS_DOWN) != 0);
                });

                // What the host did not take, Windows still gets a say in.  For
                // a plain key that costs nothing; for a sys key it is the
                // difference between Alt+F4 closing the window and doing
                // nothing at all, which is not ours to take away.
                if (claimed)
                    return 0;

                return DefWindowProcW(hwnd, message, wParam, lParam);
            }

            case WM_KEYUP:
            case WM_SYSKEYUP:
            {
                bool claimed;
                notify({ claimed = _host.onKeyUp(toKey(wParam), currentModifiers()); });

                if (claimed)
                    return 0;

                return DefWindowProcW(hwnd, message, wParam, lParam);
            }

            case WM_CHAR:
            case WM_SYSCHAR:
            {
                if (auto text = _text.take(cast(wchar) wParam))
                    notify({ _host.onTextInput(text); });

                return 0;
            }

            case WM_SETFOCUS:
                notify({ _host.onFocusChanged(true); });
                return 0;

            case WM_KILLFOCUS:
                notify({ _host.onFocusChanged(false); });
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
    // Puts the WM_CHAR stream back together into whole characters.
    TextAssembler      _text;
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
