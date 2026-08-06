module cherry.ui.application;

import core.sync.mutex : Mutex;
import std.algorithm : countUntil, remove;

import cherry.core.multicast;

/*
 * This module and cherry.ui.window import each other: a window registers
 * itself with the application that owns it, and the application closes its
 * windows.  The cycle is harmless as it stands, but it is one module
 * constructor away from being fatal.
 *
 * window.d has a `shared static this()` -- it registers the Title, Width and
 * Height properties.  D orders module constructors by the import graph, and a
 * cycle leaves it no order to choose, so the moment a second constructor
 * joins the cycle the runtime aborts before main() with
 *
 *     object.Error@src\rt\minfo.d(372): Cyclic dependency between module
 *     constructors/destructors of cherry.ui.window and cherry.ui.application
 *
 * Nothing in that message points at the import that caused it, and it fires
 * for every program built against the framework, tests included.
 *
 * So: no `shared static this()` and no `static this()` in this module.  If
 * UIApplication ever needs dependency properties of its own, register them
 * from outside the cycle -- from initialize(), or from a small module that
 * imports both and is imported by neither -- rather than from a module
 * constructor here.
 */
import cherry.ui.window : Window;

public import cherry.core.application;
public import cherry.platform.window : SessionEndReason;

public import cherry.platform.entrypoint;

/*
 * Calls an application's main in whichever of the four shapes it was written
 * -- with or without arguments, returning void or an int -- and reports an
 * exit code either way.  These are the same shapes D itself accepts for main.
 *
 * Public because it has to be: a mixin template is instantiated in the scope
 * that mixes it in, so every symbol its body names must be visible from there.
 * Nobody writes this name; ApplicationEntryPoint writes it for them.
 */
int normalizeMainCall(alias mainFn)(string[] args)
{
    static if (is(typeof(mainFn(args))))
    {
        static if (is(typeof(mainFn(args)) == void))
        { 
            mainFn(args); 
            return 0; 
        }
        else
            return cast(int) mainFn(args);
    }
    else static if (is(typeof(mainFn())))
    {
        static if (is(typeof(mainFn()) == void))
        { 
            mainFn(); 
            return 0; 
        }
        else
            return cast(int) mainFn();
    }
    else static assert(0, "App.main must be a function that takes no parameters or a string array and returns void or an int");
}

/**
 * Makes AppT the entry point of the program.
 *
 * Mixed into the module that owns the program's start-up, this supplies
 * whatever entry point the platform expects -- WinMain on Windows, so no
 * console window is created -- and routes it to AppT.main.  AppT must derive
 * from UIApplication and declare a static main taking a string array or
 * nothing, returning an int or nothing.
 *
 * Mix it in exactly once.  A second one is a second WinMain, which the linker
 * reports as a duplicate symbol without a word about where either came from.
 *
 * Example:
 * ---
 * mixin ApplicationEntryPoint!MyApp;
 *
 * class MyApp : UIApplication
 * {
 *     this(string[] args)
 *     {
 *         super(args);
 *     }
 *
 *     static int main(string[] args)
 *     {
 *         auto app = new MyApp(args);
 *         return app.run(new MainWindow);
 *     }
 * }
 * ---
 */
mixin template ApplicationEntryPoint(AppT)
{
    // Asserted rather than constrained: a template constraint that fails says
    // only that the template could not be mixed in, which is true and useless.
    static assert(is(AppT : UIApplication),
                  AppT.stringof ~ " must derive from UIApplication to be an application entry point.");
    static assert(__traits(hasMember, AppT, "main"),
                  AppT.stringof ~ " must declare a static main().");

    private static int _cherryStart(string[] args)
    {
        return normalizeMainCall!(AppT.main)(args);
    }

    mixin PlatformEntryPoint!_cherryStart;
}

/**
 * Decides what a closing window means for the application as a whole.  An
 * application is not necessarily over just because its windows are gone, and
 * which window matters differs from program to program.
 *
 * The mode is consulted every time a window unregisters, so it may be changed
 * while the application runs -- a program that opens a splash screen before
 * its real window can hold onExplicitShutdown until the latter is up.
 */
enum ShutdownMode
{
    /**
     * Shut down when the last window closes.  The default, and what a
     * single-window program wants.
     */
    onLastWindowClose,

    /**
     * Shut down when the main window closes, however many windows are still
     * open -- they are closed along with it.  This suits a program whose other
     * windows are subordinate to one: palettes, inspectors, progress windows.
     */
    onMainWindowClose,

    /**
     * Never shut down on its own: only shutdown() ends the application, and it
     * keeps running with no windows at all.  What a program needs if it must
     * outlive its windows -- one that sits in the notification area, or opens
     * a window only when asked.
     */
    onExplicitShutdown
}

alias AppActivatedEventHandler = void delegate();
alias AppSessionEndingEventHandler = void delegate(SessionEndReason reason, ref bool canClose);

/**
 * An Application that owns windows.
 *
 * Application itself knows only how to start a dispatcher and stop it, which
 * is all a program without a user interface needs.  UIApplication adds the
 * rest: the windows that are open, which of them is the main one, when the
 * application ends because of them, and the notifications that belong to the
 * program rather than to any single window -- activation and the session
 * ending.
 *
 * Windows register themselves as they are created and drop out as they are
 * destroyed, so windows() reflects what is actually open on this thread.  The
 * first window registered becomes mainWindow unless told otherwise, and the
 * role passes on to another window if that one closes.
 *
 * The application-wide notifications reach the application through the main
 * window alone.  The platform reports activation to every top-level window, so
 * listening on all of them would raise onActivated once per open window; the
 * main window stands in for the application, and the callbacks follow the role
 * wherever it goes.
 *
 * As with Application, only one instance may exist per process.
 *
 * Example:
 * ---
 * int main(string[] args)
 * {
 *     auto app = new UIApplication(args);
 *     return app.run(new Window);
 * }
 * ---
 */
class UIApplication : Application
{
    /**
     * The singleton instance of the Application class.  There can only be one
     * instance of the Application class per process.
     */
    static @property UIApplication instance()
    {
        return cast(UIApplication) Application.instance;
    }

    /**
     * Creates a new instance of the UIApplication class.
     */
    this()
    {
        _windowsMutex = new Mutex();
    }

    /**
     * Creates a new instance of the UIApplication class with the specified command
     * line arguments.  This constructor is protected to prevent multiple
     * instances of the UIApplication class from being created.
     */
    this(string[] args)
    {
        super(args);
        _windowsMutex = new Mutex();
    }

   /**
    * The shutdown mode determines when the application will exit its run loop.
    * Setting this property controls the way in which an application will exit 
    * its run loop.  
    *
    * The default is onLastWindowClose, which means that the application will 
    * exit when the last window is closed.  
    *
    * The other options are onMainWindowClose, which means that the application 
    * will exit when the main window is closed.
    * 
    * And onExplicitShutdown, which means that the application will only exit 
    * when shutdown() is called.
    */
    @property ShutdownMode shutdownMode() const 
    {
        verifyAccess();
        return _shutdownMode;
    }

    /// ditto
    @property void shutdownMode(ShutdownMode value)
    {
        verifyAccess();
        _shutdownMode = value;
    }

    /**
     * The main window is the primary window of the application.  It is the window
     * that is used to determine when the application should exit its run loop 
     * if the shutdown mode is set to onMainWindowClose.
     * The main window is set automatically when the first window is created, but
     * it can be changed by setting this property.
     */
    @property Window mainWindow() 
    {
        verifyAccess();

        return _mainWindow;
    }

    /// ditto
    @property void mainWindow(Window value)
    {
        verifyAccess();

        synchronized(_windowsMutex)
        {
            if (_windows.countUntil!(x => x is value) == -1)
                throw new Exception("The specified window is not registered with the application.");

            setMainWindow(value);
        }
    }

    /**
     * The windows property returns an array of all the windows that are currently
     * registered with the application for main thread.  This excludes windows opened 
     * in different threads with their own dispatchers.
     */
    @property Window[] windows()
    {
        verifyAccess();
        return _windows.dup;
    }

    /**
     * An event that is raised when the application is activated.  This event can be
     * used to perform any necessary actions when the application becomes active.
     */
    @event auto onActivated()
    {
        return eventAccessor(&_onActivated);
    }

    /**
     * An event that is raised when the application is deactivated.  This event can be
     * used to perform any necessary actions when the application becomes inactive.
     */
    @event auto onDeactivated()
    {
        return eventAccessor(&_onDeactivated);
    }

    /**
     * An event that is raised when the application is about to exit.  This event can be
     * used to perform any necessary actions before the application exits.
     */
    @event auto onSessionEnding()
    {
        return eventAccessor(&_onSessionEnding);
    }

    /**
     * Called when the application is activated.  This method can be overridden in a
     * derived class to perform any necessary actions when the application becomes active.
     * Overriding this method will disable the onActivated event. Call super() in 
     * the overrided method if you want the onActivated event to fire.
     */
    void activated()
    {
        _onActivated();
    }

    /**
     * Called when the application is deactivated.  This method can be overridden in a
     * derived class to perform any necessary actions when the application becomes inactive.
     * Overriding this method will disable the onDeactivated event. Call super() in
     * the overrided method if you want the onDeactivated event to fire.
     */
    void deactivated()
    {
        _onDeactivated();
    }

    /**
     * Called when the application is about to exit.  This method can be overridden in a
     * derived class to perform any necessary actions before the application exits.
     * Overriding this method will disable the onSessionEnding event. Call super() in
     * the overrided method if you want the onSessionEnding event to fire.
     *
     * Params:
     *     reason = The reason for the session ending.
     *
     * Returns:
     *     `true` if the application can close; otherwise, `false`.
     */
    bool sessionEnding(SessionEndReason reason)
    {
        bool canClose = true;
        _onSessionEnding(reason, canClose);

        return canClose;
    }

    /**
     * Runs the application with the specified main window.  This method starts the
     * application's main loop and blocks until the application is shut down. 
     *
     * Params:
     *     mainWindow = The main window of the application.
     *
     * Returns:
     *     The exit code of the application.
     */
    int run(Window mainWindow)
    {
        this.mainWindow = mainWindow;
        mainWindow.show();
        return super.run();
    }

    /**
     * Shuts down the application.  This method can be called to exit the application's
     * run loop and terminate the application.  The exit code can be specified as an
     * optional parameter.
     *
     * Params:
     *     exitCode = The exit code of the application.  The default is 0.
     */
    override void shutdown(int exitCode = 0)
    {
        verifyAccess();

        if (!_shutdownStarted) 
        {
            _shutdownStarted = true;

            foreach (w; windows)
                w.forceClose();

            super.shutdown(exitCode);
        }
    }

package(cherry):
    /**
     * Registers a window with the application.  This method is called by the window
     * when it is created.
     */
    void registerWindow(Window w)
    {
        synchronized(_windowsMutex) 
        {
            bool found;
            
            if (w.dispatcher is dispatcher)
            {
                found = (_windows.countUntil!(x => x is w) != -1);
                if (!found)
                    _windows ~= w;
            }
            else
            {
                found = (_nonAppWindows.countUntil!(x => x is w) != -1);
                if (!found)
                    _nonAppWindows ~= w;
            }

            if (found)
                throw new Exception("The specified window is already registered.");

            if (w.dispatcher is dispatcher && _mainWindow is null)
                setMainWindow(_windows[_windows.length - 1]);
        }
    }

    /**
     * Unregisters a window from the application.  This method is called by the window
     * when it is closed.
     */
    void unregisterWindow(Window w)
    {
        bool needShutdown = false;
        bool notFound = false;

        synchronized(_windowsMutex) 
        {
            if (w.dispatcher is dispatcher)
            {
                auto index = _windows.countUntil!(x => x is w);
                
                if (index != -1)
                {
                    bool isMainWindow = (_windows[index] is _mainWindow);
                    _windows = _windows.remove(index);

                    if (isMainWindow)
                    {
                        if (_shutdownMode == ShutdownMode.onMainWindowClose)
                            // The main window is closing and the shutdown mode is onMainWindowClose,
                            // so we need to shut down the application.
                            needShutdown = true;
                        else
                        {
                            Window newMainWindow = _windows.length > 0 ? _windows[_windows.length - 1] : null;
                            // The main window is closing, but the shutdown mode is not onMainWindowClose,
                            // so we need to set the main window to the last window in the list.
                            setMainWindow(newMainWindow);
                        }
                    }
                }
                else
                    notFound = true;
            }
            else
            {
                auto index = _nonAppWindows.countUntil!(x => x is w);
                if (index != -1)
                    _nonAppWindows = _nonAppWindows.remove(index);
                else
                    notFound = true;
            }

            if (notFound)
                throw new Exception("The specified window is not registered.");

            if (_shutdownMode == ShutdownMode.onLastWindowClose)
                needShutdown = (_windows.length + _nonAppWindows.length == 0);
        }

        if (needShutdown && !_shutdownStarted)
            shutdown();
    }

private:
    void setMainWindow(Window w)
    {
        if (w !is _mainWindow)
        {
            if (_mainWindow !is null)
            {
                // Remove callbacks from the old main window
                _mainWindow.activatedCallback = null;
                _mainWindow.sessionEndingCallback = null;
            }

            _mainWindow = w;
            if (_mainWindow !is null)
            {
                // Set callbacks for the new main window
                _mainWindow.activatedCallback = &appActivatedInternal;
                _mainWindow.sessionEndingCallback = &appSessionEndingInternal;
            }
        }
    }

    void appActivatedInternal(bool active)
    {
        if (active)
            activated();
        else
            deactivated();
    }

    bool appSessionEndingInternal(SessionEndReason reason)
    {
        return sessionEnding(reason);
    }

    ShutdownMode _shutdownMode;
    Window _mainWindow;
    Window[] _windows;
    Window[] _nonAppWindows;
    Mutex _windowsMutex;
    bool _shutdownStarted;

    Multicast!AppActivatedEventHandler _onActivated;
    Multicast!AppActivatedEventHandler _onDeactivated;
    Multicast!AppSessionEndingEventHandler _onSessionEnding;
}