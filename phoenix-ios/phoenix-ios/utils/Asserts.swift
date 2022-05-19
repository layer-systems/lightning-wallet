import Foundation


func assertMainThread() -> Void {
	assert(Thread.isMainThread, "Improper thread: expected main thread; Thread-unsafe code ahead")
}
