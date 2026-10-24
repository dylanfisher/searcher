/// Scores a typed query against candidate texts as a command palette does: the query's letters
/// must appear in the candidate in order, not necessarily together. Case, width and accents are
/// folded away with `NameSortKey.fold`, the fold type-to-select and filtering use.
///
/// A matched letter scores a bonus at the start of the text or of a path component (after `/`),
/// a smaller one at the start of a word (after a space or punctuation, or a capital after a
/// lowercase letter), and a run bonus right after the previous matched letter. Skipping letters
/// inside a word costs a flat penalty; moving on to a later word costs more, growing with the
/// distance. Letters that are all initials of words in one path component, such as "gh" in
/// "GitHub" or "mvd" in "my-video-downloads", keep every word-start bonus with no gap cost.
/// Otherwise letters kept in one word beat letters spread over words: "prj1" ranks "Project 1"
/// above "pr-junk-1". The best alignment is found by dynamic programming over the folded bytes,
/// so a later word start can win over the first occurrence of a letter.
///
/// Prepare each candidate once with `Candidate`; a keystroke then only scores. Matching works on
/// the folded UTF-8 bytes, with a multi-byte character's bytes kept together.
public struct FuzzyMatcher: Sendable {
    /// A text prepared for matching: folded once, with each byte's word position worked out, so
    /// a keystroke only scores it.
    public struct Candidate: Sendable {
        public let text: String
        /// One unit per byte of the folded text: the byte in the low 8 bits, its `Position` above.
        let units: [UInt16]
        /// For a text that isn't all ASCII, the UTF-8 offset in `text` of the character each
        /// folded byte comes from. Nil when the folded bytes line up with `text`'s, as ASCII does.
        let origins: [Int32]?

        public init(_ text: String) {
            self.text = text
            var units: [UInt16] = []
            if text.utf8.allSatisfy({ $0 < 0x80 }) {
                // Folding ASCII only lowercases, so offsets match and the capitals of `text`
                // still show where camel-case words start.
                units.reserveCapacity(text.utf8.count)
                var previous: (byte: UInt8, original: UInt8)?
                for (byte, original) in zip(NameSortKey.fold(text).utf8, text.utf8) {
                    units.append(Self.unit(byte, original: original, after: previous))
                    previous = (byte, original)
                }
                origins = nil
            } else {
                // Folding character by character tells which character each folded byte came
                // from, for the match's ranges. Camel case isn't looked for.
                var offsets: [Int32] = []
                var offset = 0
                var previous: (byte: UInt8, original: UInt8)?
                for character in text {
                    for byte in NameSortKey.fold(String(character)).utf8 {
                        units.append(Self.unit(byte, original: nil, after: previous))
                        offsets.append(Int32(offset))
                        previous = (byte, 0)
                    }
                    offset += character.utf8.count
                }
                origins = offsets
            }
            self.units = units
        }

        /// `byte` with its position, from the byte before it. `original` is the unfolded byte,
        /// nil when the text isn't ASCII.
        private static func unit(
            _ byte: UInt8, original: UInt8?, after previous: (byte: UInt8, original: UInt8)?
        ) -> UInt16 {
            let position: Position
            if isSeparator(byte) {
                position = .separator
            } else if let previous {
                if previous.byte == UInt8(ascii: "/") {
                    position = .componentStart
                } else if isSeparator(previous.byte) {
                    position = .wordStart
                } else if let original, isCapital(original), !isCapital(previous.original) {
                    position = .wordStart
                } else {
                    position = .inWord
                }
            } else {
                position = .componentStart
            }
            return UInt16(byte) | UInt16(position.rawValue) << 8
        }

        /// ASCII other than letters and digits. Bytes of other characters are letters.
        private static func isSeparator(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                UInt8(ascii: "A")...UInt8(ascii: "Z"), 0x80...:
                false
            default: true
            }
        }

        private static func isCapital(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        }
    }

    /// Where a folded byte sits in its text.
    enum Position: UInt8 {
        case inWord, wordStart, componentStart, separator
    }

    /// Bonuses and penalties in score points. Every candidate that matches matches every query
    /// letter, so only the differences between these count. Moving on to a new word costs more
    /// than a word start earns, so letters kept in one word beat letters spread over word
    /// starts; an initials chain is exempt.
    static let componentStartBonus: Int32 = 10
    static let wordStartBonus: Int32 = 8
    static let runBonus: Int32 = 6
    static let gapOpenPenalty: Int32 = 3
    static let gapBytePenalty: Int32 = 1
    static let newWordPenalty: Int32 = 10
    /// A cell no alignment reaches; far enough from Int32's limits that adding penalties to it
    /// can't overflow.
    private static let unreachable: Int32 = .min / 4

    /// The folded query's bytes.
    private let query: [UInt8]

    public init(_ query: String) {
        self.query = Array(NameSortKey.fold(query).utf8)
    }

    /// The best alignment's score, or nil when `candidate` doesn't hold the query's letters in
    /// order. An empty query scores 0 against every candidate.
    public func score(_ candidate: Candidate) -> Int? {
        var scratch = Scratch()
        return score(candidate, in: &scratch)
    }

    /// The score and the matched ranges of `candidate.text`, or nil when it doesn't match.
    public func match(_ candidate: Candidate) -> FuzzyMatch? {
        var scratch = Scratch()
        return align(candidate, in: &scratch) { table, end, score in
            FuzzyMatch(
                score: score,
                ranges: ranges(of: positions(endingAt: end, in: table), in: candidate))
        }
    }

    /// The `limit` best matches of `candidates`, best first, with their indexes in
    /// `candidates`. Equal scores rank the shorter folded text first, then the earlier index.
    public func best(_ candidates: [Candidate], limit: Int) -> [(index: Int, match: FuzzyMatch)] {
        precondition(limit >= 0, "a negative limit \(limit)")
        guard limit > 0 else { return [] }
        // One scratch for every candidate: it grows to the longest, and scoring the rest
        // allocates nothing.
        var scratch = Scratch()
        // Kept sorted best first. A binary insertion into at most `limit` entries is cheaper
        // than sorting every match when most candidates match.
        var top: [Ranked] = []
        top.reserveCapacity(limit + 1)
        for (index, candidate) in candidates.enumerated() {
            guard let score = score(candidate, in: &scratch) else { continue }
            let ranked = Ranked(score: score, length: candidate.units.count, index: index)
            if top.count == limit, let last = top.last, !(ranked < last) { continue }
            var low = 0
            var high = top.count
            while low < high {
                let middle = (low + high) / 2
                if top[middle] < ranked { low = middle + 1 } else { high = middle }
            }
            top.insert(ranked, at: low)
            if top.count > limit { top.removeLast() }
        }
        return top.map { ranked in
            guard let match = match(candidates[ranked.index]) else {
                preconditionFailure("\(candidates[ranked.index].text) scored but didn't match")
            }
            return (ranked.index, match)
        }
    }

    /// A scored candidate, ordered best first.
    private struct Ranked: Comparable {
        let score: Int
        let length: Int
        let index: Int

        static func < (a: Ranked, b: Ranked) -> Bool {
            if a.score != b.score { return a.score > b.score }
            if a.length != b.length { return a.length < b.length }
            return a.index < b.index
        }
    }

    /// Storage for the alignment tables, reused across candidates and grown as needed.
    private struct Scratch {
        var cells: [Int32] = []
        var chains: [Int32] = []
        var windows: [Int] = []

        mutating func reserve(rows m: Int, columns n: Int) {
            if cells.count < m * n {
                cells = [Int32](repeating: 0, count: m * n * 2)
                chains = cells
            }
            if windows.count < 2 * m { windows = [Int](repeating: 0, count: 2 * m) }
        }
    }

    /// The alignment tables for one candidate.
    ///
    /// Cell `i * n + j` holds the best score of the query's first `i + 1` bytes with byte `i` at
    /// candidate byte `j`; `chains` holds the same for alignments whose letters so far are all
    /// initials of words in one path component. Only cells inside byte `i`'s window are written:
    /// `windows[i]` is the first place a greedy scan from the left can put it, `windows[m + i]`
    /// the last place one from the right can.
    private struct Table {
        let cells: UnsafeMutableBufferPointer<Int32>
        let chains: UnsafeMutableBufferPointer<Int32>
        let windows: UnsafeMutableBufferPointer<Int>
        let units: UnsafeBufferPointer<UInt16>
        let query: UnsafeBufferPointer<UInt8>
        var m: Int { query.count }
        var n: Int { units.count }
    }

    private func score(_ candidate: Candidate, in scratch: inout Scratch) -> Int? {
        align(candidate, in: &scratch) { _, _, score in score }
    }

    /// Fills the tables for `candidate` and passes them to `body` with the end of the best
    /// alignment and its score; nil when nothing aligns. An empty query passes no tables.
    private func align<Result>(
        _ candidate: Candidate, in scratch: inout Scratch,
        _ body: (Table?, Int, Int) -> Result
    ) -> Result? {
        let m = query.count
        let n = candidate.units.count
        guard m > 0 else { return body(nil, -1, 0) }
        guard m <= n else { return nil }
        scratch.reserve(rows: m, columns: n)
        return scratch.cells.withUnsafeMutableBufferPointer { cells in
            scratch.chains.withUnsafeMutableBufferPointer { chains in
                scratch.windows.withUnsafeMutableBufferPointer { windows in
                    candidate.units.withUnsafeBufferPointer { units in
                        query.withUnsafeBufferPointer { query in
                            let table = Table(
                                cells: cells, chains: chains, windows: windows, units: units,
                                query: query)
                            guard Self.findWindows(table) else { return nil }
                            Self.fill(table)
                            var end = -1
                            var best = Self.unreachable
                            for j in windows[m - 1]...windows[2 * m - 1]
                            where cells[(m - 1) * n + j] > best {
                                best = cells[(m - 1) * n + j]
                                end = j
                            }
                            guard end >= 0 else { return nil }
                            return body(table, end, Int(best))
                        }
                    }
                }
            }
        }
    }

    /// Fills `windows`; false when a query byte is missing, which rejects most candidates
    /// without a table.
    private static func findWindows(_ table: Table) -> Bool {
        let (m, n, units, query, windows) = (
            table.m, table.n, table.units, table.query, table.windows
        )
        var j = 0
        for i in 0..<m {
            while j < n && byte(units[j]) != query[i] { j += 1 }
            guard j < n else { return false }
            windows[i] = j
            j += 1
        }
        j = n - 1
        for i in stride(from: m - 1, through: 0, by: -1) {
            while byte(units[j]) != query[i] { j -= 1 }
            windows[m + i] = j
            j -= 1
        }
        return true
    }

    private static func fill(_ table: Table) {
        let (m, n, units, query) = (table.m, table.n, table.units, table.query)
        let (cells, chains, windows) = (table.cells, table.chains, table.windows)
        for j in windows[0]...windows[m] {
            let matches = byte(units[j]) == query[0]
            cells[j] = matches ? bonus(units[j]) : unreachable
            chains[j] = matches && startsWord(units[j]) ? bonus(units[j]) : unreachable
        }
        for i in 1..<m {
            let row = i * n
            let previousRow = row - n
            let previousFirst = windows[i - 1]
            let previousLast = windows[m + i - 1]
            // A continuation byte must follow its lead byte, so a character matches whole, and
            // it adds nothing: a character scores as one letter whatever its length.
            let isContinuation = Self.isContinuation(query[i])
            // The best earlier cells: for a gap into a later word as score + gapBytePenalty *
            // position, so the gap's cost to position j is a subtraction; for a gap within j's
            // word as the score; for an initials chain, the chain score in j's component.
            var anyWord = unreachable
            var sameWord = unreachable
            var chain = unreachable
            var wordStart = previousFirst
            while wordStart > 0 && !startsWord(units[wordStart]) { wordStart -= 1 }
            for j in (previousFirst + 1)...windows[m + i] {
                if j - 1 <= previousLast { chain = max(chain, chains[previousRow + j - 1]) }
                if position(units[j]) == .componentStart { chain = unreachable }
                if startsWord(units[j]) {
                    wordStart = j
                    sameWord = unreachable
                }
                let k = j - 2
                if k >= previousFirst && k <= previousLast && cells[previousRow + k] > unreachable {
                    let value = cells[previousRow + k]
                    anyWord = max(anyWord, value + gapBytePenalty * Int32(k))
                    if k >= wordStart { sameWord = max(sameWord, value) }
                }
                guard j >= windows[i] else { continue }
                guard byte(units[j]) == query[i] else {
                    cells[row + j] = unreachable
                    chains[row + j] = unreachable
                    continue
                }
                let adjacent = j - 1 <= previousLast ? cells[previousRow + j - 1] : unreachable
                var best = unreachable
                var chained = unreachable
                if isContinuation {
                    best = adjacent
                    chained = j - 1 <= previousLast ? chains[previousRow + j - 1] : unreachable
                } else {
                    if adjacent > unreachable { best = adjacent + runBonus }
                    if anyWord > unreachable {
                        best = max(
                            best,
                            anyWord + bonus(units[j]) - gapOpenPenalty - gapBytePenalty
                                * Int32(j - 1) - newWordPenalty)
                    }
                    if sameWord > unreachable { best = max(best, sameWord - gapOpenPenalty) }
                    if position(units[j]) == .wordStart && chain > unreachable {
                        chained = chain + wordStartBonus
                    }
                }
                chains[row + j] = chained
                cells[row + j] = max(best, chained)
            }
        }
    }

    /// The candidate byte each query byte sits at in the alignment ending at `end`, found by
    /// retracing which earlier cell each cell's score came from.
    private func positions(endingAt end: Int, in table: Table?) -> [Int] {
        guard let table else { return [] }
        let (m, n, units, query) = (table.m, table.n, table.units, table.query)
        let (cells, chains, windows) = (table.cells, table.chains, table.windows)
        let unreachable = Self.unreachable
        var positions = [Int](repeating: 0, count: m)
        var j = end
        positions[m - 1] = j
        for i in stride(from: m - 1, to: 0, by: -1) {
            let row = i * n
            let previousRow = row - n
            let previousFirst = windows[i - 1]
            let previousLast = windows[m + i - 1]
            let value = cells[row + j]
            let isChain = chains[row + j] > unreachable && chains[row + j] == value
            let previous: Int?
            if Self.isContinuation(query[i]) {
                previous = j - 1
            } else if isChain {
                var componentStart = j
                while componentStart > 0 && Self.position(units[componentStart]) != .componentStart
                {
                    componentStart -= 1
                }
                previous = stride(
                    from: min(j - 1, previousLast), through: max(previousFirst, componentStart),
                    by: -1
                ).first { chains[previousRow + $0] + Self.wordStartBonus == value }
            } else if j - 1 <= previousLast && cells[previousRow + j - 1] > unreachable
                && cells[previousRow + j - 1] + Self.runBonus == value
            {
                previous = j - 1
            } else {
                var wordStart = j
                while wordStart > 0 && !Self.startsWord(units[wordStart]) { wordStart -= 1 }
                let bonus = Self.bonus(units[j])
                previous = stride(from: min(j - 2, previousLast), through: previousFirst, by: -1)
                    .first { k in
                        let earlier = cells[previousRow + k]
                        guard earlier > unreachable else { return false }
                        if k >= wordStart { return earlier - Self.gapOpenPenalty == value }
                        return earlier + bonus - Self.gapOpenPenalty - Self.gapBytePenalty
                            * Int32(j - k - 1) - Self.newWordPenalty == value
                    }
            }
            guard let previous else {
                preconditionFailure("no earlier cell gives \(value) at \(i), \(j)")
            }
            j = previous
            positions[i - 1] = j
        }
        return positions
    }

    /// The characters of `candidate.text` holding `positions`, adjacent ones joined.
    private func ranges(of positions: [Int], in candidate: Candidate) -> [Range<String.Index>] {
        let utf8 = candidate.text.utf8
        var offsets: [Range<Int>] = []
        for position in positions {
            let character: Range<Int>
            if let origins = candidate.origins {
                let start = Int(origins[position])
                var next = position + 1
                while next < origins.count && origins[next] == origins[position] { next += 1 }
                character = start..<(next < origins.count ? Int(origins[next]) : utf8.count)
            } else {
                character = position..<(position + 1)
            }
            if let last = offsets.last, last.upperBound >= character.lowerBound {
                offsets[offsets.count - 1] =
                    last.lowerBound..<max(last.upperBound, character.upperBound)
            } else {
                offsets.append(character)
            }
        }
        return offsets.map {
            utf8.index(
                utf8.startIndex, offsetBy: $0.lowerBound)..<utf8.index(
                    utf8.startIndex, offsetBy: $0.upperBound)
        }
    }

    private static func byte(_ unit: UInt16) -> UInt8 {
        UInt8(truncatingIfNeeded: unit)
    }

    private static func isContinuation(_ byte: UInt8) -> Bool {
        byte & 0xC0 == 0x80
    }

    private static func position(_ unit: UInt16) -> Position {
        Position(rawValue: UInt8(unit >> 8))!
    }

    private static func startsWord(_ unit: UInt16) -> Bool {
        switch position(unit) {
        case .wordStart, .componentStart: true
        case .inWord, .separator: false
        }
    }

    private static func bonus(_ unit: UInt16) -> Int32 {
        switch position(unit) {
        case .componentStart: componentStartBonus
        case .wordStart: wordStartBonus
        case .inWord, .separator: 0
        }
    }
}
