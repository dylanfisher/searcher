import Foundation

/// The raw samples of the UI bench, in milliseconds, as `.build/bench-ui.json` holds them. The app
/// writes one launch's samples; the bench runner appends every launch's and writes the whole set.
/// Each span is timed from its start to the Core Animation commit of the frame that shows it.
public struct UIBenchRecord: Sendable, Codable, Equatable {
    /// Process start → first window frame (B1), one per launch.
    public var launch: [Double]
    /// Open W1 → frame with its first rows (B2.W1).
    public var openW1: [Double]
    /// Open W2 → frame with its first rows (B2.W2).
    public var openW2: [Double]
    /// ↓ key event timestamp → frame with the moved selection, on W2 (B6).
    public var keyDown: [Double]
    /// Sort column change → frame with the re-sorted rows, on W2 (B8).
    public var sortChange: [Double]
    /// Every run loop pass over the stall threshold (B10), all launches together.
    public var stalls: [Stall]

    /// One stall and the span its run loop pass belongs to (`TimedSpan.name(coveringPassFrom:)`).
    public struct Stall: Sendable, Codable, Equatable {
        public let milliseconds: Double
        /// A span's name, or `UIBenchRecord.betweenSpans`.
        public let span: String

        public init(milliseconds: Double, span: String) {
            self.milliseconds = milliseconds
            self.span = span
        }
    }

    /// The span name of a stall reported while no span was running.
    public static let betweenSpans = "between spans"

    public init(
        launch: [Double] = [], openW1: [Double] = [], openW2: [Double] = [],
        keyDown: [Double] = [], sortChange: [Double] = [], stalls: [Stall] = []
    ) {
        self.launch = launch
        self.openW1 = openW1
        self.openW2 = openW2
        self.keyDown = keyDown
        self.sortChange = sortChange
        self.stalls = stalls
    }

    /// Adds `other`'s samples after these.
    public mutating func append(_ other: UIBenchRecord) {
        launch += other.launch
        openW1 += other.openW1
        openW2 += other.openW2
        keyDown += other.keyDown
        sortChange += other.sortChange
        stalls += other.stalls
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> UIBenchRecord {
        try JSONDecoder().decode(UIBenchRecord.self, from: data)
    }
}
