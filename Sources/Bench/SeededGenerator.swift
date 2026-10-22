/// SplitMix64: the same seed gives the same sequence on every machine and Swift version, so
/// generated fixtures repeat. The range and element helpers are defined here rather than taken
/// from `Int.random(in:using:)`, whose algorithm the standard library doesn't promise to keep.
struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `range`. The multiply-high reduction has a bias under 2⁻³², which fixtures don't
    /// notice.
    mutating func int(in range: ClosedRange<Int>) -> Int {
        let width = UInt64(range.upperBound - range.lowerBound) + 1
        return range.lowerBound + Int(next().multipliedFullWidth(by: width).high)
    }

    mutating func element<Element>(of array: [Element]) -> Element {
        array[int(in: 0...array.count - 1)]
    }
}
