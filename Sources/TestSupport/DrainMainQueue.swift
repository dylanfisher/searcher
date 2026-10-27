import Dispatch

/// Returns once the main queue has run every block queued on it before this call.
public func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}
