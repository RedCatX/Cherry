module cherry.ui.application_test;

/**
 * Tests for UIApplication.
 *
 * They live outside application.d so that the class stays free of the test
 * doubles it is driven with, the same arrangement cherry.core.obj_test uses.
 *
 * Windows are registered by hand here.  That is what Window's constructor
 * will do once it is wired up, and doing it explicitly keeps each test to the
 * one thing it is about.
 */

version (unittest):

import std.exception : assertThrown;

import cherry.platform : SessionEndReason;
import cherry.ui.application;
import cherry.ui.testing;
import cherry.ui.window;

// ===========================================================================
// The main window, and the callbacks that follow it
// ===========================================================================

unittest // the first window registered becomes the main one
{
    withApplication((app, loop) {
        assert(app.mainWindow is null);

        auto first = makeWindow();
        assert(app.mainWindow is first.window);

        auto second = makeWindow();
        assert(app.mainWindow is first.window, "a later window does not take over");
        assert(app.windows.length == 2);
    });
}

unittest // the application hears about activation through its main window
{
    withApplication((app, loop) {
        auto main = makeWindow();

        int activated;
        int deactivated;
        app.onActivated ~= () { activated++; };
        app.onDeactivated ~= () { deactivated++; };

        main.platform.host.onActivationChanged(true);
        assert(activated == 1 && deactivated == 0);

        main.platform.host.onActivationChanged(false);
        assert(activated == 1 && deactivated == 1);
    });
}

unittest // and only through that one, however many windows are open
{
    withApplication((app, loop) {
        auto main = makeWindow();
        auto other = makeWindow();

        int activated;
        app.onActivated ~= () { activated++; };

        // The platform tells every top-level window; listening on one is what
        // keeps the application from hearing it once per window.
        other.platform.host.onActivationChanged(true);
        assert(activated == 0, "a window that is not the main one reports nothing");

        main.platform.host.onActivationChanged(true);
        assert(activated == 1);
    });
}

unittest // closing the main window hands the role, and the callbacks, on
{
    withApplication((app, loop) {
        auto first = makeWindow();
        auto second = makeWindow();

        app.shutdownMode = ShutdownMode.onExplicitShutdown;
        first.close();

        assert(app.mainWindow is second.window, "the role passes to a window that remains");

        int activated;
        app.onActivated ~= () { activated++; };

        second.platform.host.onActivationChanged(true);
        assert(activated == 1, "...and the callbacks moved with it");

        first.platform.host.onActivationChanged(true);
        assert(activated == 1, "the window that left reports nothing any more");
    });
}

// ===========================================================================
// The session ending
// ===========================================================================

unittest // a handler that refuses is answered back to the platform
{
    withApplication((app, loop) {
        auto main = makeWindow();

        SessionEndReason seen;
        bool refuse;

        app.onSessionEnding ~= (SessionEndReason reason, ref bool canClose) {
            seen = reason;
            if (refuse)
                canClose = false;
        };

        assert(main.platform.host.onSessionEnding(SessionEndReason.logoff),
               "nobody objected, so the session may end");
        assert(seen == SessionEndReason.logoff, "the reason reaches the handler");

        refuse = true;
        assert(!main.platform.host.onSessionEnding(SessionEndReason.shutdown),
               "an objection reaches the platform as a refusal");
        assert(seen == SessionEndReason.shutdown);
    });
}

unittest // with nothing listening the session simply ends
{
    withApplication((app, loop) {
        auto main = makeWindow();

        assert(main.platform.host.onSessionEnding(SessionEndReason.logoff));
    });
}

// ===========================================================================
// Shutdown modes
// ===========================================================================

unittest // onMainWindowClose: the main window going ends the application
{
    withApplication((app, loop) {
        auto main = makeWindow();
        auto other = makeWindow();

        app.shutdownMode = ShutdownMode.onMainWindowClose;
        assert(!app.dispatcher.hasShutdownStarted);

        other.close();
        assert(!app.dispatcher.hasShutdownStarted, "any other window may go freely");

        main.close();
        assert(app.dispatcher.hasShutdownStarted);
    });
}

unittest // onLastWindowClose: the application outlives all but the last
{
    withApplication((app, loop) {
        auto first = makeWindow();
        auto second = makeWindow();

        app.shutdownMode = ShutdownMode.onLastWindowClose;

        second.close();
        assert(!app.dispatcher.hasShutdownStarted);

        first.close();
        assert(app.dispatcher.hasShutdownStarted);
    });
}

unittest // onExplicitShutdown: an empty desktop is not a reason to stop
{
    withApplication((app, loop) {
        auto only = makeWindow();

        app.shutdownMode = ShutdownMode.onExplicitShutdown;
        only.close();

        assert(app.windows.length == 0);
        assert(!app.dispatcher.hasShutdownStarted,
               "the application waits to be told, not to run out of windows");
    });
}

// ===========================================================================
// The register keeps its books straight
// ===========================================================================

unittest // a window registers once, and only a registered window unregisters
{
    withApplication((app, loop) {
        auto w = makeWindow();

        assertThrown(app.registerWindow(w), "registering twice is a mistake worth hearing about");

        auto stranger = makeWindow();
        stranger.close();
        assertThrown(app.unregisterWindow(stranger));

        app.shutdownMode = ShutdownMode.onExplicitShutdown;
        w.close();

        assert(app.windows.length == 0);
        assertThrown(app.unregisterWindow(w), "and it does not unregister twice either");
    });
}
