import Darwin

/// One run loop pass that took longer than the stall threshold.
public struct Stall: Sendable {
    /// When the pass started: the run loop woke or was entered.
    public let start: ContinuousClock.Instant
    /// When the run loop was about to wait again.
    public let end: ContinuousClock.Instant

    /// Return addresses on the stalled thread, innermost first, captured once the pass crossed the
    /// threshold. Empty when the pass ended before the watchdog thread got to capture it.
    public let frames: [UInt]

    public init(start: ContinuousClock.Instant, end: ContinuousClock.Instant, frames: [UInt]) {
        self.start = start
        self.end = end
        self.frames = frames
    }

    public var duration: Duration { end - start }

    /// The symbol name for each frame, or its address in hex when no loaded image exports one.
    /// Swift names come out mangled; they still contain the function's name.
    public var symbols: [String] {
        frames.map { address in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0,
                let name = info.dli_sname
            else { return "0x" + String(address, radix: 16) }
            return String(cString: name)
        }
    }
}
