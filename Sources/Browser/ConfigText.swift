import Foundation

/// The config file's text, read and changed as the user wrote it: a change replaces one value's
/// text, or puts in or takes out one key, and leaves every comment, blank line, space and key
/// order around it (docs/decisions/0126-config-comments.md).
///
/// The text is JSON with `//` and `/* */` comments and a comma allowed after an object's last
/// key, as Sublime Text's settings are. `ConfigFile.parse` refuses text that `scan` can't read,
/// and only text it took without an error is changed.
struct ConfigText {
    private(set) var bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    // MARK: - Comments

    /// Why text can't be read past its comments: a block comment not closed, on its line.
    struct UnclosedComment: Error {
        let line: Int
    }

    /// `bytes` with each comment's bytes made spaces, its line breaks kept, so the text reads as
    /// JSON with every byte at the offset and on the line the file has it; and which bytes are
    /// in a comment.
    static func blankingComments(_ bytes: [UInt8]) -> Result<
        (bytes: [UInt8], inComment: [Bool]), UnclosedComment
    > {
        var blanked = bytes
        var inComment = [Bool](repeating: false, count: bytes.count)
        func blank(_ index: Int) {
            inComment[index] = true
            if bytes[index] != newline, bytes[index] != carriageReturn { blanked[index] = space }
        }
        var line = 1
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == quote {
                index = stringEnd(bytes, from: index)
                continue
            }
            if byte == newline { line += 1 }
            let next = index + 1 < bytes.count ? bytes[index + 1] : nil
            if byte == slash, next == slash {
                while index < bytes.count, bytes[index] != newline {
                    blank(index)
                    index += 1
                }
                continue
            }
            if byte == slash, next == star {
                let opened = line
                blank(index)
                blank(index + 1)
                index += 2
                while index < bytes.count,
                    !(bytes[index] == star && index + 1 < bytes.count
                        && bytes[index + 1] == slash)
                {
                    if bytes[index] == newline { line += 1 }
                    blank(index)
                    index += 1
                }
                guard index < bytes.count else { return .failure(UnclosedComment(line: opened)) }
                blank(index)
                blank(index + 1)
                index += 2
                continue
            }
            index += 1
        }
        return .success((blanked, inComment))
    }

    /// `bytes`, its comments already blanked, with each comma after an object's or array's last
    /// item made a space, so Foundation's parser takes it. A comma with no item before it, as in
    /// `{,}`, stays, and is an error.
    static func blankingTrailingCommas(_ bytes: [UInt8]) -> [UInt8] {
        var blanked = bytes
        // The last two bytes that aren't whitespace, the later one last.
        var previous: Int?
        var last: Int?
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == quote {
                index = stringEnd(bytes, from: index)
                (previous, last) = (last, index - 1)
                continue
            }
            if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]"), let last,
                bytes[last] == comma, let previous,
                ![comma, UInt8(ascii: "{"), UInt8(ascii: "[")].contains(bytes[previous])
            {
                blanked[last] = space
            }
            if !isWhitespace(byte) { (previous, last) = (last, index) }
            index += 1
        }
        return blanked
    }

    // MARK: - Reading the shape

    /// An object's place in the text, and its keys'.
    struct Object {
        /// The offsets of its `{` and `}`.
        let open: Int
        let close: Int
        let members: [Member]

        func member(_ name: String) -> Member? {
            members.first { $0.name == name }
        }
    }

    /// A key and its value's place in the text.
    struct Member {
        let name: String
        /// The offset of the key's opening quote.
        let keyStart: Int
        /// The value's text is `valueStart..<valueEnd`.
        let valueStart: Int
        let valueEnd: Int
        /// The offset of the comma after the value, if one follows it.
        let comma: Int?
        /// The value, when it is an object.
        let object: Object?
    }

    /// Why the scan can't read the text's shape: what it found, at an offset.
    struct ScanError: Error {
        let offset: Int
        let reason: String
    }

    /// The top-level object of `bytes`, a config file's text, or where its shape isn't one the
    /// edits can read. `ConfigFile.parse` refuses text this refuses, so a file the app patches
    /// always scans.
    static func scan(_ bytes: [UInt8]) throws(ScanError) -> Object {
        let blanked: [UInt8]
        switch blankingComments(bytes) {
        case .success(let result): blanked = result.bytes
        case .failure: throw ScanError(offset: 0, reason: "a /* comment isn't closed")
        }
        // An editor may start the file with a byte order mark; it stays where it is.
        let start = blanked.starts(with: byteOrderMark) ? byteOrderMark.count : 0
        var index = skippingWhitespace(blanked, from: start)
        guard index < blanked.count, blanked[index] == UInt8(ascii: "{") else {
            throw ScanError(offset: index, reason: "the text doesn't start with {")
        }
        let root = try object(blanked, at: &index)
        index = skippingWhitespace(blanked, from: index)
        guard index == blanked.count else {
            throw ScanError(offset: index, reason: "there is text after the closing }")
        }
        return root
    }

    /// The text's top-level object. The text is one `ConfigFile.parse` took, or one an edit
    /// made from it, so it scans.
    var root: Object {
        do {
            return try Self.scan(bytes)
        } catch {
            preconditionFailure("the config file's text didn't scan: \(error.reason)")
        }
    }

    /// The object whose `{` is at `index`, in text whose comments are blanked; moves `index`
    /// past its `}`.
    private static func object(_ text: [UInt8], at index: inout Int) throws(ScanError) -> Object {
        let open = index
        index += 1
        var members: [Member] = []
        while true {
            index = skippingWhitespace(text, from: index)
            guard index < text.count else {
                throw ScanError(offset: open, reason: "a { isn't closed")
            }
            if text[index] == UInt8(ascii: "}") { break }
            guard text[index] == quote else {
                throw ScanError(offset: index, reason: "a key isn't a string in quotes")
            }
            let keyStart = index
            index = stringEnd(text, from: index)
            let name = try Self.name(Array(text[keyStart..<index]), at: keyStart)
            index = skippingWhitespace(text, from: index)
            guard index < text.count, text[index] == UInt8(ascii: ":") else {
                throw ScanError(offset: keyStart, reason: "a key has no : after it")
            }
            let valueStart = skippingWhitespace(text, from: index + 1)
            index = valueStart
            guard index < text.count else {
                throw ScanError(offset: keyStart, reason: "a key has no value")
            }
            let object: Object? =
                text[index] == UInt8(ascii: "{") ? try Self.object(text, at: &index) : nil
            if object == nil { index = valueEnd(text, from: index) }
            let valueEnd = index
            guard valueEnd > valueStart else {
                throw ScanError(offset: keyStart, reason: "a key has no value")
            }
            index = skippingWhitespace(text, from: index)
            var separator: Int?
            if index < text.count, text[index] == comma {
                separator = index
                index += 1
            } else if index >= text.count || text[index] != UInt8(ascii: "}") {
                throw ScanError(offset: valueEnd, reason: "a value has no , or } after it")
            }
            members.append(
                Member(
                    name: name, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd,
                    comma: separator, object: object))
        }
        let close = index
        index += 1
        return Object(open: open, close: close, members: members)
    }

    /// A key's name from its text at `offset`, quotes and all, escapes read as JSON reads them.
    private static func name(_ quoted: [UInt8], at offset: Int) throws(ScanError) -> String {
        guard quoted.count >= 2, quoted.last == quote else {
            throw ScanError(offset: offset, reason: "a key's string isn't closed")
        }
        guard quoted.contains(backslash) else {
            return String(decoding: quoted.dropFirst().dropLast(), as: UTF8.self)
        }
        guard
            let name = try? JSONSerialization.jsonObject(
                with: Data(quoted), options: .fragmentsAllowed) as? String
        else { throw ScanError(offset: offset, reason: "a key isn't a JSON string") }
        return name
    }

    /// The offset just past a value that isn't an object, starting at `index`.
    private static func valueEnd(_ text: [UInt8], from index: Int) -> Int {
        if text[index] == quote { return stringEnd(text, from: index) }
        if text[index] == UInt8(ascii: "[") {
            var depth = 0
            var end = index
            repeat {
                if text[end] == quote {
                    end = stringEnd(text, from: end)
                    continue
                }
                if text[end] == UInt8(ascii: "[") || text[end] == UInt8(ascii: "{") { depth += 1 }
                if text[end] == UInt8(ascii: "]") || text[end] == UInt8(ascii: "}") { depth -= 1 }
                end += 1
            } while depth > 0 && end < text.count
            return end
        }
        var end = index
        while end < text.count, !isWhitespace(text[end]),
            ![comma, UInt8(ascii: "}"), UInt8(ascii: "]")].contains(text[end])
        {
            end += 1
        }
        return end
    }

    // MARK: - Changing it

    /// Replaces `member`'s value with `value`, JSON's text for it.
    mutating func replace(_ member: Member, with value: String) {
        bytes.replaceSubrange(member.valueStart..<member.valueEnd, with: Array(value.utf8))
    }

    /// Puts `member`, a key and its value as JSON text, into `object` after its last key, at
    /// that key's indent, with `comment`'s lines above it as `//` comments, a blank line before
    /// them. An object on one line gets it on that line, with no comment, and an empty one on
    /// lines of its own. A comma after the last key, which the text may have, is matched.
    mutating func insert(_ member: String, comment: [String], into object: Object) {
        let inComment = Self.comments(bytes).inComment
        let last = object.members.last
        let anchor = last.map { ($0.comma ?? ($0.valueEnd - 1)) + 1 } ?? object.open + 1
        let trailing = last?.comma != nil ? "," : ""
        let keyIndent =
            last.flatMap { startsLine($0.keyStart) ? indent(of: $0.keyStart) : nil }
            ?? indent(of: object.open) + indentUnit
        let nl = lineEnding
        let commentLines = comment.map { "\(keyIndent)// \($0)\(nl)" }.joined()
        let lineBreak = (anchor..<object.close).first { bytes[$0] == newline && !inComment[$0] }
        if var lineBreak {
            if lineBreak > anchor, bytes[lineBreak - 1] == carriageReturn { lineBreak -= 1 }
            let gap = comment.isEmpty || last == nil ? "" : nl
            insert("\(nl)\(gap)\(commentLines)\(keyIndent)\(member)\(trailing)", at: lineBreak)
            if let last, last.comma == nil { insert(",", at: last.valueEnd) }
        } else if last != nil {
            insert(trailing.isEmpty ? ", \(member)" : " \(member),", at: anchor)
        } else {
            let closing = indent(of: object.open)
            insert("\(nl)\(commentLines)\(keyIndent)\(member)\(nl)\(closing)", at: object.close)
        }
    }

    /// The file's line break: `\r\n` when its first line ends with one, else `\n`.
    private var lineEnding: String {
        guard let first = bytes.firstIndex(of: newline) else { return "\n" }
        return first > 0 && bytes[first - 1] == carriageReturn ? "\r\n" : "\n"
    }

    /// Takes `object`'s member at `index` out, with the comma that separates it from the next
    /// key, or from the one before when it is the last; and its line, when nothing else is on
    /// it. Comments outside its text stay.
    mutating func remove(_ index: Int, from object: Object) {
        let member = object.members[index]
        var start = member.keyStart
        var end = member.valueEnd
        var before: Int?
        if let comma = member.comma {
            end = comma + 1
            while end < bytes.count, bytes[end] == space || bytes[end] == tab { end += 1 }
        } else if index > 0 {
            before = object.members[index - 1].comma
        }
        let lineStart = self.lineStart(start)
        let lineEnd = bytes[end...].firstIndex(of: newline) ?? bytes.count
        let blankBefore = bytes[lineStart..<start].allSatisfy { $0 == space || $0 == tab }
        let blankAfter = bytes[end..<lineEnd].allSatisfy {
            $0 == space || $0 == tab || $0 == carriageReturn
        }
        if blankBefore, blankAfter, lineEnd < bytes.count {
            start = lineStart
            end = lineEnd + 1
        }
        bytes.removeSubrange(start..<end)
        if let before { bytes.remove(at: before) }
    }

    private mutating func insert(_ text: String, at index: Int) {
        bytes.insert(contentsOf: Array(text.utf8), at: index)
    }

    /// The offset of the first byte of `index`'s line.
    private func lineStart(_ index: Int) -> Int {
        (bytes[..<index].lastIndex(of: newline)).map { $0 + 1 } ?? 0
    }

    /// The spaces and tabs that start `index`'s line.
    private func indent(of index: Int) -> String {
        let start = lineStart(index)
        let end = bytes[start...].firstIndex { $0 != space && $0 != tab } ?? bytes.count
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    /// Whether only spaces and tabs come before `index` on its line.
    private func startsLine(_ index: Int) -> Bool {
        bytes[lineStart(index)..<index].allSatisfy { $0 == space || $0 == tab }
    }

    /// One level of the file's indent: its first key's, or two spaces.
    private var indentUnit: String {
        guard let first = root.members.first, startsLine(first.keyStart) else { return "  " }
        let unit = indent(of: first.keyStart)
        return unit.isEmpty ? "  " : unit
    }

    // MARK: - Bytes

    /// `blankingComments` for text that parsed, which has every comment closed.
    private static func comments(_ bytes: [UInt8]) -> (bytes: [UInt8], inComment: [Bool]) {
        switch blankingComments(bytes) {
        case .success(let blanked): return blanked
        case .failure: preconditionFailure("a comment in the config file isn't closed")
        }
    }

    /// The offset just past the string whose opening quote is at `index`. JSON escapes a line
    /// break in a string, so an unclosed one ends at the end of the text.
    private static func stringEnd(_ bytes: [UInt8], from index: Int) -> Int {
        var end = index + 1
        while end < bytes.count, bytes[end] != quote {
            if bytes[end] == backslash { end += 1 }
            end += 1
        }
        return min(end + 1, bytes.count)
    }

    private static func skippingWhitespace(_ bytes: [UInt8], from index: Int) -> Int {
        var index = index
        while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
        return index
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == space || byte == tab || byte == newline || byte == carriageReturn
    }
}

private let quote = UInt8(ascii: "\"")
private let backslash = UInt8(ascii: "\\")
private let slash = UInt8(ascii: "/")
private let star = UInt8(ascii: "*")
private let comma = UInt8(ascii: ",")
private let space = UInt8(ascii: " ")
private let tab = UInt8(ascii: "\t")
private let newline = UInt8(ascii: "\n")
private let carriageReturn = UInt8(ascii: "\r")
private let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
