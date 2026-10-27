import Dispatch

/// A serial queue, suspended: work sent to it waits until the test calls `resume()`.
public func heldQueue(_ label: String) -> DispatchQueue {
    let queue = DispatchQueue(label: label)
    queue.suspend()
    return queue
}
