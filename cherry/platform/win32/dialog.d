module cherry.platform.win32.dialog;

version (Windows):

import core.sys.windows.windows;
import std.utf : toUTF16z;

import cherry.platform.dialog;

pragma(lib, "user32");

/**
 * MessageBox with no owner window: the caller may have none, or the one it
 * has may be the thing that failed.  MB_TASKMODAL disables the thread's
 * windows for the duration, which is what an ownerless modal box needs to
 * behave like one.
 */
void win32ShowMessage(string title, string text, MessageKind kind)
{
    UINT flags = MB_OK | MB_TASKMODAL | MB_SETFOREGROUND;

    final switch (kind)
    {
        case MessageKind.information:
            flags |= MB_ICONINFORMATION;
            break;

        case MessageKind.warning:
            flags |= MB_ICONWARNING;
            break;

        case MessageKind.error:
            flags |= MB_ICONERROR;
            break;
    }

    MessageBoxW(null, text.toUTF16z(), title.toUTF16z(), flags);
}
