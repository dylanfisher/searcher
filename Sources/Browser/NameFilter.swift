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
        /// How many matches of a filter with this text have run on the main thread, for tests that
        /// check filtering stays off it. Keyed by text, not task-local, so work a pane hops to the
        /// main queue still counts; a test uses a query of its own, so other tests' matches don't
        /// land in its count. Debug builds only.
        static func mainThreadMatches(for text: String) -> Int {
            mainThreadMatchCounts.value(of: Array(NameSortKey.fold(text).utf8))
        }

        private static let mainThreadMatchCounts = Counts()

        private final class Counts: @unchecked Sendable {
            private let lock = NSLock()
            private var counts: [[UInt8]: Int] = [:]

            func value(of key: [UInt8]) -> Int { lock.withLock { counts[key, default: 0] } }
            func increment(_ key: [UInt8]) { lock.withLock { counts[key, default: 0] += 1 } }
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
            if Thread.isMainThread { Self.mainThreadMatchCounts.increment(folded) }
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
