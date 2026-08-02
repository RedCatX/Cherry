module cherry.core.dispatcher.types;

/**
 * An enunmeration describing the priorities at which operations 
 * can be invoked via the Dispatcher.
 */
enum DispatcherPriority : int
{
    invalid         = -1,
    /// Operations at this priority are not processed
    inactive        = 0,
    /// Operations at this priority are processed when the system is idle
    systemIdle      = 1,
    /// Operations at this priority are processed when the application is idle
    applicationIdle = 2,
    /// Operations at this priority are processed when the context is idle
    contextIdle     = 3,
    /// Operations at this priority are processed after all other non-idle operations are done
    background      = 4,
    /// Operations at this priority are processed at the same priority as input
    input           = 5,
    /// Operations at this priority are processed when layout and render is
	/// done but just before items at input priority are serviced. Specifically
	/// this is used while firing the Loaded event
    loaded          = 6,
    /// Operations at this priority are processed at the same priority as rendering
    render          = 7,
    /// Operations at this priority are processed at the same priority as data binding
    dataBind        = 8,
    /// Operations at this priority are processed at normal priority
    normal          = 9,
    /// Operations at this priority are processed before other asynchronous operations
    send            = 10
}

/**
 * Whether the value names one of the queue's priority bands.
 *
 * The bands are array indices, so `invalid` -- or any integer cast into the
 * enum from outside its range -- would index past the array.  The checks
 * below therefore throw rather than assert: contracts are compiled out in
 * release builds, which is exactly where an out-of-range index does damage
 * instead of tripping a bounds check.
 */
package bool isQueueBand(DispatcherPriority p) pure nothrow @nogc
{
    return p >= DispatcherPriority.inactive && p <= DispatcherPriority.send;
}

/**
 * An enunmeration describing the status of a DispatcherOperation
 */
enum OperationStatus 
{ 
    /// The operation is pending in queue
	pending,
    /// The operation has started executing, but has not completed yet
	executing, 
    /// The operation has been completed
	completed, 
    /// The operation has been aborted
	aborted 
}
