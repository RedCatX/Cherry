module cherry.platform.dialog;

/**
 * Native dialogs: the ones an application should never draw itself.
 *
 * Unlike the rest of the platform layer, this is a plain function rather than
 * an interface behind a factory -- there is no object here, and nothing to
 * own or dispose.  The other seams abstract a thing with a lifetime; this one
 * abstracts a single blocking call.
 */

version (Windows)
{
    import cherry.platform.win32.dialog : win32ShowMessage;
}

/**
 * How the message should be presented.
 */
enum MessageKind
{
    information,
    warning,
    error
}

/**
 * Shows a system message and returns once the user dismisses it.
 *
 * Deliberately the system's own dialog rather than one of the framework's
 * windows: this is what reports a failure, and by then the framework may be
 * exactly what is broken.  It also runs the platform's own modal loop, so no
 * queued work of ours runs while it is up -- for an error report that is a
 * feature, since letting a broken application process another hundred events
 * is worse than making it wait.
 */
void showMessage(string title, string text, MessageKind kind = MessageKind.error)
{
    version (Windows)
    {
        win32ShowMessage(title, text, kind);
    }
    else
    {
        import std.stdio : stderr;

        try
            stderr.writefln("[%s] %s: %s", kind, title, text);
        catch (Exception)
        {
        }
    }
}
