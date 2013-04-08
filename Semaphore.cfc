/*
	Semaphore.cfc - simulates a counting semaphore which throttles requests to a particular resource/block of code to prevent
	overloading the JVM with long running requests which may be CPU/RAM bound.

	Upon starvation of available threads we do not add a FIFO process queue. This is to prevent CF threads being tied up waiting
	for a semaphore thread. Instead the application should simply return a message to the end user to try again later.
 */
component displayname="Semaphore" output="false"
{

	/**
	* @hint Semaphore class constructor
	* @param {string} lockName What to name the cflock when requesting a thread so we don't conflict with any other application processes
	* @param {numeric} threadCount How many threads will be made available to service a particular request type
	* @param {string} logFile Name of the system log file to write to
	* @param {boolean} verboseLogging Whether to turn on verbose logging to the user defined system log file
	*/
	public any function init(required string lockName, required numeric threadCount, required string logFile, boolean verboseLogging = false, boolean throwOnerror = false)
	{
		variables.instance = {
			counter = 1,												// Counter holds the next thread count to be assigned
			failedAcquireCount = 0,										// A count of the sequential failed attempts to acquire a thread (reset once a thread is available)
			gcTimeSecs = 30,											// Time between garbage collection sweeps to collect lost threads
			lockName = arguments.lockName,							// Name of the ColdFusion lock
			locks = {},													// Structure to hold locks (inc. time stamps)
			logFile = arguments.logFile,									// Which system log file to write to
			maxThreadCount = arguments.threadCount,				// How many total threads are allowed
			nextGC = 0,													// Initial time for the next garbage collection
			staleLockTimeoutSecs = 90,									// How old should a lock be before it is considered stale and can be garbage collected
			throwOnerror = arguments.throwOnerror,					// Whether to throw an exception on error, or just write to the log file
			verboseLogging = arguments.verboseLogging				// Turn on extra logging to the (user defined) system log file
		};

		setGCInterval();	// Set the garbage collection interval

		return this;
	}


	/**
	* @hint Request an available thread.  Returns positive integer (threadId) if successful and 0 if none are available
	*/
	public numeric function acquireThread()
	{
		var threadId = 0;

		try
		{
			lock name=variables.instance.lockName type="exclusive" timeout="1" throwontimeout="true"
			{
				// Check if we should garbage collect any stale threads first
				if (getTickCount() > variables.instance.nextGC)
				{
					doGarbageCollection();
				}

				// See if we have any spare threads available, if so then decrement the available thread count and return the threadId
				if (structCount(variables.instance.locks) < variables.instance.maxThreadCount)
				{
					// Store the threadId to return
					threadId = variables.instance.counter;
					// Create a new lock and store the tick count (keyed by the threadId) for later cleanup
					variables.instance.locks[threadId] = getTickCount();
					// Increment the counter for the next requested thread
					variables.instance.counter++;
					// Reset the failed count
					variables.instance.failedAcquireCount = 0;

					// If we done this many transactions then reset to 1 to prevent hitting CF's max number limit
					if (variables.instance.counter > 1000000)
					{
						variables.instance.counter = 1;
						writeLog(text="Semaphore.acquireThread() Thread counter reset", type="information", file=variables.instance.logFile);
					}

					if (variables.instance.verboseLogging)
					{
						writeLog(text="Semaphore.acquireThread() Thread acquired: thread=#threadId# used=#structCount(variables.instance.locks)# max=#variables.instance.maxThreadCount#", type="information", file=variables.instance.logFile);
					}
				}
				else
				{
					variables.instance.failedAcquireCount++;
					writeLog(text="Semaphore.acquireThread() Failed to acquire thread (#variables.instance.lockName#) - None available. used=#structCount(variables.instance.locks)# max=#variables.instance.maxThreadCount# sequential failed attempts=#variables.instance.failedAcquireCount#", type="error", file=variables.instance.logFile);
				}
			}
		}
		catch (any e)
		{
			threadId = 0;
			writeLog(text="Semaphore.acquireThread() Error acquiring lock/thread - Cause: #e.message#", type="error", file=variables.instance.logFile);
			if (variables.instance.throwOnError)
			{
				rethrow();
			}
		}

		return threadId;
	}


	/**
	* @hint Returns the current thread count used
	*/
	public numeric function getUsedThreadCount()
	{
		lock name=variables.instance.lockName type="readonly" timeout="1" throwontimeout="true"
		{
			return structCount(variables.instance.locks);
		}
	}


	/**
	* @hint Releases a locked thread from the pool. This MUST be called from the application, after
	* the requested process has run (either successfully or unsuccessfully)
	* @param {numeric} threadId The `threadId` returned from acquireThread()
	*/
	public void function releaseThread(required numeric threadId)
	{
		try
		{
			lock name=variables.instance.lockName type="exclusive" timeout="10" throwontimeout="true"
			{
				structDelete(variables.instance.locks, arguments.threadId);

				if (variables.instance.verboseLogging)
				{
					writeLog(text="Semaphore.releaseThread() Thread released: thread=#arguments.threadId# used=#structCount(variables.instance.locks)# max=#variables.instance.maxThreadCount#", type="information", file=variables.instance.logFile);
				}
			}
		}
		catch (any e)
		{
			writeLog(text="Semaphore.releaseThread() Failed to release thread (lockname: #variables.instance.lockName# thread: #arguments.threadId#) #e.message#", type="error", file=variables.instance.logFile);
			if (variables.instance.throwOnError)
			{
				rethrow();
			}
		}
	}


	/**
	* @hint Looks for threads older than 'n' and removes any locks that may have died to prevent starvation
	* We are already locked when this method is called, so variables are safe to modify.
	* Is run every #gcTimeSecs# to check for lost threads i.e. that weren't  released due to being swallowed
	* by long running thread handler.  It is NOT an excuse for not properly releasing threads using releaseThread()
	*/
	private void function doGarbageCollection()
	{
		try
		{
			var gcCount = 0;
			var lock = "";
			var staleThreshold = getTickCount() - (1000 * variables.instance.staleLockTimeoutSecs);

			// Loop over all the lock struct looking for stale locks, delete any if found
			for(lock IN variables.instance.locks)
			{
				if (variables.instance.locks[lock] < staleThreshold)
				{
					structDelete(variables.instance.locks, lock);
					gcCount++;
				}
			}

			// Log if we found old threads to clean up. Logging this as an error as the application shouldn't ever have stale threads
			if (gcCount > 0)
			{
				writeLog(text="Semaphore.doGarbageCollection() We just garbage collected #gcCount# threads", type="error", file=variables.instance.logFile);
			}

			// Reset the garbage collection interval
			setGCInterval();
		}
		catch (any e)
		{
			writeLog(text="Semaphore.doGarbageCollection() #e.message#", type="error", file=variables.instance.logFile);
			if (variables.instance.throwOnError)
			{
				rethrow();
			}
		}
	}


	/**
	* @hint Sets/resets the garbage collection interval used to check for stale threads
	*/
	private void function setGCInterval()
	{
		variables.instance.nextGC = getTickCount() + (1000 * variables.instance.gcTimeSecs);
	}

}
