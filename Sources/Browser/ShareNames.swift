import Foundation

/// The share names in `smbutil view`'s output, and the key two names are matched by. The parse is
/// strict, so a change in the tool's format shows as `ShareListError.unparsable` and never as a
/// wrong list (docs/decisions/0115-server-shares.md).
public enum ShareNames {
    /// The types `smbutil` prints a share as.
    private static let types = ["Disk", "Pipe", "Printer", "Comm"].map { Array($0.utf8) }
    /// The width `smbutil` pads a name to, in bytes (its format is `%-48s%-8s%s`).
    private static let nameWidth = 48

    /// The disk shares `output` lists, in the server's order, without those whose name ends in
    /// `$`. The output is a header line starting `Share` with `Type` and `Comments`, a line of
    /// dashes, one row per share, a blank line and `<n> shares listed`, with `n` the row count.
    /// Throws `unparsable` for output in any other shape, a row of an unknown type, or bytes that
    /// aren't UTF-8.
    public static func parse(_ output: Data) throws(ShareListError) -> [String] {
        guard let text = String(bytes: output, encoding: .utf8) else { throw .unparsable }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        if lines.last == "" { lines = lines.dropLast() }
        guard let header = lines.popFirst(), header.hasPrefix("Share"),
            header.contains("Type"), header.contains("Comments"),
            let dashes = lines.popFirst(), !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" })
        else { throw .unparsable }
        var rows: [(name: String, type: [UInt8])] = []
        while let line = lines.first, !line.isEmpty, !isTrailer(line) {
            rows.append(try row(line))
            lines = lines.dropFirst()
        }
        if lines.first == "" { lines = lines.dropFirst() }
        guard lines.count == 1, let count = lines.first.flatMap(trailerCount), count == rows.count
        else { throw .unparsable }
        return rows.filter { $0.type == types[0] && !$0.name.hasSuffix("$") }.map(\.name)
    }

    /// The key a share's name is matched by: its canonical (NFC) form without case, since SMB
    /// share names are case-insensitive and macOS may hand a name decomposed.
    public static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(
            options: .caseInsensitive, locale: nil)
    }

    /// The name and type in a row. The name is everything before the first type token that ends
    /// the line or is followed by a space and comes after the name's padding: a run of two or more
    /// spaces, or, for a name of 47 bytes, one, or, for a longer name, none. A name that itself
    /// holds two spaces then a type token is split there; that can't be told from the columns.
    private static func row(_ line: Substring) throws(ShareListError) -> (String, [UInt8]) {
        let bytes = Array(line.utf8)
        for start in bytes.indices {
            guard let type = types.first(where: { isType($0, in: bytes, at: start) }) else {
                continue
            }
            var nameEnd = start
            while nameEnd > 0, bytes[nameEnd - 1] == UInt8(ascii: " ") { nameEnd -= 1 }
            let padding = start - nameEnd
            let fits =
                switch padding {
                case 0: nameEnd >= nameWidth
                case 1: nameEnd == nameWidth - 1
                default: true
                }
            guard nameEnd > 0, fits else { continue }
            // The name ends before an ASCII byte, so it is whole UTF-8.
            return (String(decoding: bytes[..<nameEnd], as: UTF8.self), type)
        }
        throw .unparsable
    }

    /// Whether `type` is at `start` in `bytes`, followed by a space or the end.
    private static func isType(_ type: [UInt8], in bytes: [UInt8], at start: Int) -> Bool {
        let end = start + type.count
        guard end <= bytes.count, bytes[start..<end].elementsEqual(type) else { return false }
        return end == bytes.count || bytes[end] == UInt8(ascii: " ")
    }

    private static func isTrailer(_ line: Substring) -> Bool {
        trailerCount(line) != nil
    }

    /// `n` in a line `<n> shares listed` (or `1 share listed`), nil for any other line.
    private static func trailerCount(_ line: Substring) -> Int? {
        let words = line.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, words[1] == "shares" || words[1] == "share",
            words[2] == "listed", words[0].allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return Int(words[0])
    }
}
