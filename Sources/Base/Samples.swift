/// Values from repeated runs, summarized by nearest-rank percentiles: a percentile is always one
/// of the measured values, never an interpolation between two.
public struct Samples: Sendable, Equatable {
    /// The values in ascending order.
    public let sorted: [Double]

    /// - Precondition: `values` is not empty; a summary of no runs has no meaning.
    public init(_ values: [Double]) {
        precondition(!values.isEmpty, "Samples needs at least one value")
        sorted = values.sorted()
    }

    /// The smallest value with at least `percent`% of the samples at or below it.
    public func percentile(_ percent: Int) -> Double {
        precondition((1...100).contains(percent), "percentile \(percent) is outside 1...100")
        // Integer ceiling of percent × count / 100; a Double product can land just past a whole
        // rank and round up one too far.
        let rank = (percent * sorted.count + 99) / 100
        return sorted[rank - 1]
    }

    public var median: Double { percentile(50) }
    public var p95: Double { percentile(95) }
}
