module cherry.core.threading;

/**
 * Thread affinity: which thread an object belongs to, and how work reaches it.
 *
 * Not threading primitives.  There is no thread, no mutex and no pool here --
 * D has those in core.thread and std.concurrency, and this package does not
 * compete with them.  What it owns is the rule every object in the framework
 * lives under: an object belongs to one thread, only that thread may touch it,
 * and anything else asks that thread to do the touching.  The dispatcher is
 * how the asking works -- a per-thread work queue with a message loop over it.
 *
 * Importing this package module brings in the public surface -- the priority
 * and status vocabulary, DispatcherObject, DispatcherOperation and Dispatcher
 * itself.  The queue behind them stays internal to the package.
 */

public import cherry.core.threading.dispatcher;
public import cherry.core.threading.frame;
public import cherry.core.threading.operation;
public import cherry.core.threading.timer;
public import cherry.core.threading.types;
