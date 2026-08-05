module cherry.core.application;

import cherry.core.multicast;
import cherry.core.dispatcher;
import cherry.platform.dialog;

/**
 * The Application class is the entry point for a Cherry application.  It
 * manages the application's lifetime, including startup, shutdown, and
 * unhandled exception handling.
 */
class Application : DispatcherObject
{
    /**
     * The singleton instance of the Application class.  There can only be one
     * instance of the Application class per process.
     */
    static @property Application instance()
    {
        return _instance;
    }

    /**
     * Creates a new instance of the Application class.  This constructor is
     * protected to prevent multiple instances of the Application class from
     * being created.
     */
    this()
    {
        if (_instance !is null)
            throw new Exception("An Application instance already exists.");

        _instance = this;
    }

    /**
     * Creates a new instance of the Application class with the specified command
     * line arguments.  This constructor is protected to prevent multiple
     * instances of the Application class from being created.
     */
    this(string[] args)
    {
        this();
        _args = args;
    }

    /**
     * The command line arguments passed to the application.
     */
    @property string[] args() const
    {
        return _args.dup();
    }

    /**
     * Indicates whether the application has been shut down.
     */
    @property bool isShutdown()
    {
        verifyAccess();
        return dispatcher.hasShutdownFinished;
    }

    /**
     * The exit code of the application.  This property is set when the application
     * is shut down.
     */
    @property int exitCode()
    {
        verifyAccess();
        return _exitCode;
    }

    /**
     * An event that is raised when an unhandled exception occurs in the
     * application.  This event can be used to log the exception, show a message
     * to the user, or perform any other necessary actions before the application
     * exits.
     */
    @event auto onUnhandledException() 
    {
        return dispatcher.onUnhandledException;
    }

	/**
	* An event that is raised when the application is about to exit.  This event can be
	* used to perform any necessary actions before the application exits.
	*/
    @event auto onExit() 
	{ 
		return dispatcher.onShutdownStarted; 
	}

    /**
     * Initializes the application.  This method is called before the application's
     * main loop is started.  Override this method to perform any necessary
     * initialization tasks.
     */
    void initialize()
    {
    }

    /**
     * Handles unhandled exceptions in the application.  This method is called when an
     * unhandled exception occurs.  Override this method to perform any necessary
     * actions to handle the exception.
     */
    void unhandledException(shared(DispatcherOperation) operation, Exception exception, ref bool handled)
    {
        if (!handled)
        {
            showMessage(typeid(exception).toString, exception.msg);
            handled = true;
        }
    }

    /**
     * Runs the application.  This method starts the application's main loop and
     * blocks until the application is shut down.  Override this method to perform
     * any necessary actions before the main loop is started.
     * 
     * Returns:
     *     The exit code of the application.  This value is set when the application
     *     is shut down.
     */
    int run()
    {
        verifyAccess();

        if (dispatcher.hasShutdownFinished)
            throw new Exception("Cannot run the application after it has been shut down.");

        initialize();

        dispatcher.onUnhandledException ~= &unhandledException;
        (cast(Dispatcher) dispatcher).run();

        return _exitCode;
    }

    /**
     * Shuts down the application.  This method is called to terminate the application.
     *
     * Params:
     *     exitCode = The exit code to return from the application.  Defaults to 0.
     */
    void shutdown(int exitCode = 0)
    {
        verifyAccess();

        _exitCode = exitCode;
        dispatcher.shutdown();
        _instance = null;
    }

private:
    __gshared Application _instance;
    string[] _args;
    int _exitCode;
}