import Base
import Foundation

/// The text typed into a pane's filter field, and the match that keeps a row: the entry's folded
/// name contains the folded text, so "port" keeps "Report.pdf" and "PORTFOLIO"
/// (0037-type-to-filter.md). `Listing` applies it with the hidden and folders-first settings, off
/// the main thread; an empty filter keeps every entry.
public struct NameFilter: Sendable, Equatable {
    /// The text as typed, for showing.
    public let text: String
    /// `NameSortKey.fold` of `text`, as UTF-8 bytes. Matching compares bytes, as the fold asks.
    private let folded: [UInt8]

    #if DEBUG
        /// How many matches have run on the main thread, for tests that check filtering stays off
        /// it. Debug builds only.
        static var mainThreadMatches: Int { mainThreadMatchCount.value }
        private static let mainThreadMatchCount = Counter()

        private final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0

            var value: Int { lock.withLock { count } }
            func increment() { lock.withLock { count += 1 } }
        }
    #endif

    public init(_ text: String = "") {
        self.text = text
        folded = Array(NameSortKey.fold(text).utf8)
    }

    /// Keeps every entry: nothing typed, or only marks the fold drops.
    public var isEmpty: Bool { folded.isEmpty }

    /// Whether `foldedName`, a name as `NameSortKey.fold` folds it, contains the folded text.
    public func matches(foldedName: String) -> Bool {
        guard !folded.isEmpty else { return true }
        #if DEBUG
            if Thread.isMainThread { Self.mainThreadMatchCount.increment() }
        #endif
        var name = foldedName
        return name.withUTF8 { name in
            folded.withUnsafeBufferPointer { query in
                memmem(name.baseAddress, name.count, query.baseAddress, query.count) != nil
            }
        }
    }

    /// Filters that fold to the same text keep the same rows, so "Port" and "port" are equal.
    public static func == (a: NameFilter, b: NameFilter) -> Bool {
        a.folded == b.folded
    }
}
