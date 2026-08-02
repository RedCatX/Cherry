module cherry.core.dispatcher;

/**
 * The dispatcher: a thread's work queue and message loop.
 *
 * Importing this package module brings in the public surface -- the priority
 * and status vocabulary, DispatcherObject, DispatcherOperation and Dispatcher
 * itself.  The queue behind them stays internal to the package.
 */

public import cherry.core.dispatcher.dispatcher;
public import cherry.core.dispatcher.operation;
public import cherry.core.dispatcher.timer;
public import cherry.core.dispatcher.types;
