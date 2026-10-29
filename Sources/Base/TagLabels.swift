/// The colors of an item's Finder tags, which its row shows as dots: the color label number of
/// each tag that has a color, 1 to 7, in the order of the item's tags, each color once. Held in
/// four bits a label, so `DirectoryEntry` keeps it in padding it already had and a listing of
/// 100k entries takes no more memory for it (docs/decisions/0124-tags-in-rows-and-preview.md).
public struct TagLabels: Hashable, Sendable, Sequence {
    /// Each label in four bits, the first in the lowest; 0 ends the list. Seven colors take 28.
    private let bits: UInt32

    /// No colors.
    public init() {
        bits = 0
    }

    /// The labels of `labels` that are colors, in order, each once; 0, a tag without a color,
    /// is left out.
    public init(_ labels: some Sequence<Int>) {
        var bits: UInt32 = 0
        var seen: Set<Int> = []
        var shift: UInt32 = 0
        for label in labels where label != 0 && seen.insert(label).inserted {
            precondition((1...7).contains(label), "\(label) isn't a color label")
            bits |= UInt32(label) << shift
            shift += 4
        }
        self.bits = bits
    }

    public var isEmpty: Bool { bits == 0 }

    public var count: Int { (32 - bits.leadingZeroBitCount + 3) / 4 }

    public func makeIterator() -> AnyIterator<Int> {
        var rest = bits
        return AnyIterator {
            guard rest != 0 else { return nil }
            defer { rest >>= 4 }
            return Int(rest & 0xF)
        }
    }
}
