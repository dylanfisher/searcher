import Browser

/// A monitor that only counts stops.
public final class StubMonitor: FolderMonitoring {
    public private(set) var stopCount = 0

    public init() {}

    public func stop() { stopCount += 1 }
}
