import UniformTypeIdentifiers

/// A type whose apps `StubSystemActions` listed, and whether it did on the main thread.
public struct AppLookup: Sendable {
    public let type: UTType
    public let onMainThread: Bool

    public init(type: UTType, onMainThread: Bool) {
        self.type = type
        self.onMainThread = onMainThread
    }
}
