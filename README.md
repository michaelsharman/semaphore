# Semaphore.cfc

Simulates a [counting semaphore](http://en.wikipedia.org/wiki/Semaphore_(programming)) which throttles requests to a particular resource/block of code to prevent overloading the JVM with long running requests which may be CPU/RAM bound.

Upon starvation of available threads we do not add a FIFO process queue. This is to prevent CF threads being tied up waiting for a semaphore thread. Instead the application should simply return a message to the end user to try again later.

## Requirements
Written to run as a singleton on Railo 3.2+ or ColdFusion 9+

## Usage
``` ColdFusion
// Instantiate as a singleton
Semaphore = new lib.utils.Semaphore(lockName = "my_lock", threadCount = 15, logFile = application.applicationname, verboseLogging = false),
```

Surround your application code block with a check for a spare thread
``` ColdFusion
var threadId = Semaphore.acquireThread();
if (threadId > 0)
{
	... // Heavy application code to go here

	// Release the process thread back into the pool
	Semaphore.releaseThread(threadId);
}
else // No thread acquired
{
	// set  your return status code, indicating resource is unavailable, and a response to the user;
	getPageContext().getResponse().setstatus(423);
	response = {
		"status": false,
		"message": "The server is too busy to process this request, please try again later"
	};
}
```
