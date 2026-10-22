/// A named stretch of time, such as one span of the UI bench, for filing things that happened
/// during it.
public struct TimedSpan: Sendable, Equatable {
    public let name: String
    public let start: ContinuousClock.Instant
    public let end: ContinuousClock.Instant

    public init(name: String, start: ContinuousClock.Instant, end: ContinuousClock.Instant) {
        self.name = name
        self.start = start
        self.end = end
    }

    /// The span a run loop pass from `start` to `end` belongs to: the first span it overlaps, or
    /// nil. Spans run one after another and never overlap, so a pass overlaps two only when it
    /// ends one span and the next begins in it; it goes to the earlier one. A pass can start
    /// before its span (a span begins partway through the pass doing its work) and end after it
    /// (the pass that commits the span's frame).
    public static func name(
        coveringPassFrom start: ContinuousClock.Instant, to end: ContinuousClock.Instant,
        in spans: [TimedSpan]
    ) -> String? {
        spans.first { $0.start < end && start < $0.end }?.name
    }
}
