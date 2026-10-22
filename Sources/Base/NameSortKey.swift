import Foundation

/// A byte string whose order follows Finder's name order (`localizedStandardCompare`), so a
/// listing sorts by name with byte comparisons instead of collating names on every compare.
///
/// Case, accents and width are folded away and digit runs compare by value, so names that differ
/// only in those share a key; a caller that needs a total order breaks ties itself. Characters
/// order as the root collation does: whitespace, punctuation, symbols, currency, digits, then
/// letters by script — Latin, Greek, Cyrillic, Georgian, Armenian, Hebrew, Arabic, other scripts,
/// Hangul, kana, Bopomofo, Han. Latin, Cyrillic and Arabic letters follow tables of their
/// alphabets; other scripts follow code point order. `NameSortKeyTests` lists the known
/// differences from `localizedStandardCompare`.
public struct NameSortKey: Sendable, Hashable, Comparable {
    private let bytes: [UInt8]

    /// - Precondition: no digit run in `name` has more than 255 digits after its leading zeros.
    ///   A file name is at most 255 bytes, so only a string that can't be a file name traps.
    public init(_ name: String) {
        var builder = Builder()
        builder.bytes.reserveCapacity(name.utf8.count * 2)
        if name.utf8.allSatisfy({ $0 < 0x80 }) {
            // Most names are ASCII, where folding only lowercases; skipping the Foundation
            // passes below halves the build time.
            for byte in name.utf8 {
                let lowercased = (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
                builder.append(Unicode.Scalar(lowercased))
            }
        } else {
            // Canonical decomposition splits accents off their letters and Hangul syllables into
            // jamo. Folding with `.diacriticInsensitive` instead would also turn й into и, which
            // the root order keeps apart.
            let folded = name.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            for scalar in folded.decomposedStringWithCanonicalMapping.unicodeScalars {
                builder.append(scalar)
            }
        }
        bytes = builder.bytes
    }

    public static func < (a: NameSortKey, b: NameSortKey) -> Bool {
        a.bytes.lexicographicallyPrecedes(b.bytes)
    }

    /// The keys for `names`, in the same order, built in parallel chunks. Call it off the main
    /// thread.
    public static func keys(for names: [String]) -> [NameSortKey] {
        // Spike S4 built 100k keys in 40 ms on one thread and 8 ms in 8 chunks. Below two
        // chunks' worth of names, dispatching costs more than it saves.
        let chunkCount = min(8, names.count / 1_000)
        guard chunkCount > 1 else { return names.map(NameSortKey.init) }
        return [NameSortKey](unsafeUninitializedCapacity: names.count) { buffer, count in
            // Each chunk initializes its own range of indexes, so no two threads touch one key.
            nonisolated(unsafe) let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                let start = names.count * chunk / chunkCount
                let end = names.count * (chunk + 1) / chunkCount
                for index in start..<end {
                    (base + index).initialize(to: NameSortKey(names[index]))
                }
            }
            count = names.count
        }
    }
}

/// The first byte of each character's encoding. Its order is the order of the character classes.
private enum Class {
    static let whitespace: UInt8 = 0x01
    static let punctuationOrSymbol: UInt8 = 0x02
    static let digitRun: UInt8 = 0x03
    static let otherNumber: UInt8 = 0x04
    static let latin: UInt8 = 0x05
    static let greek: UInt8 = 0x06
    static let cyrillic: UInt8 = 0x07
    static let georgian: UInt8 = 0x08
    static let armenian: UInt8 = 0x09
    static let hebrew: UInt8 = 0x0A
    static let arabic: UInt8 = 0x0B
    static let otherLetter: UInt8 = 0x0C
    static let hangul: UInt8 = 0x0D
    static let kana: UInt8 = 0x0E
    static let bopomofo: UInt8 = 0x0F
    static let han: UInt8 = 0x10
    static let unassigned: UInt8 = 0x11
}

/// The second byte of a punctuation mark or symbol. ASCII and common punctuation and symbols take
/// a rank in root collation order. Others follow the ranked ones of their kind, in code point
/// order.
enum Mark {
    static let punctuation = "_-‐‑‒–—―〜・,、;:!¡?¿.。·'‘’‚‹›\"“”„«»()[]{}「」『』【】§¶@*/\\&#%†‡•′″※"
    static let symbols = "`´^¯¨¸°©®+±÷×<=>¬|¦~"
    static let otherPunctuation: UInt8 = 0x40
    static let otherSymbol: UInt8 = 0x70
    static let currency: UInt8 = 0x71
    /// The root order spells an ellipsis as three periods.
    static let ellipsis: Unicode.Scalar = "…"
    static let period: Unicode.Scalar = "."
}

/// Encodings of the letters whose root order differs from code point order: the class byte and
/// a rank for each letter. A letter that the root order treats as a sequence (æ as ae) encodes
/// as that sequence; one it treats as another letter (ø as o) shares that letter's encoding.
enum Alphabet {
    static let latin = "abcdeǝəfghiıjklmnŋopqĸrstŧuvwxyzþ"
    static let latinSpellings: [Unicode.Scalar: String] = [
        "ª": "a", "º": "o", "æ": "ae", "ð": "d", "đ": "d", "ø": "o", "ħ": "h", "ĳ": "ij",
        "ŀ": "l", "ł": "l", "œ": "oe", "ǆ": "dz", "ǳ": "dz", "ǉ": "lj", "ǌ": "nj",
    ]
    static let cyrillic = "абвгдђеєжзѕиійјклљмнњопрстћуфхцчџшщъыьэюя"
    static let cyrillicSpellings: [Unicode.Scalar: String] = ["ґ": "г"]
    static let arabic = "ءآأؤإئابپةتثجچحخدذرزژسشصضطظعغفقكکگلمنهوىيی"

    /// Rank bytes are below this; a letter of these scripts missing from its table follows the
    /// table, in code point order.
    static let unlisted: UInt8 = 0xFF

    /// The letter a base letter and a combining mark spell when the root order keeps that letter
    /// apart from its base. Canonical decomposition has split it in two.
    static func composed(_ base: Unicode.Scalar, _ mark: Unicode.Scalar) -> Unicode.Scalar? {
        switch (base, mark) {
        case ("и", "\u{306}"): "й"
        case ("ا", "\u{653}"): "آ"
        case ("ا", "\u{654}"): "أ"
        case ("ا", "\u{655}"): "إ"
        case ("و", "\u{654}"): "ؤ"
        case ("ي", "\u{654}"): "ئ"
        default: nil
        }
    }
}

/// A letter's class and rank bytes, two per letter, stored inline so a table of them holds no
/// references.
private struct LetterEncoding: Sendable {
    let bytes: (UInt8, UInt8, UInt8, UInt8)
    let count: Int

    init(_ bytes: [UInt8]) {
        precondition(bytes.count <= 4, "a letter spells at most two letters")
        let padded = bytes + [0, 0, 0, 0]
        self.bytes = (padded[0], padded[1], padded[2], padded[3])
        count = bytes.count
    }
}

/// A read-only map from scalars to values in memory that is written once and never freed.
///
/// Tables made of arrays or dictionaries, or held by a class, cost a retain and release of shared
/// storage on each name or character. Threads building keys in parallel contend on those
/// reference counts: in a release build, 8 chunks built 100k keys in about 16 ms when each key
/// retained one shared class instance, and in 8–10 ms with these tables.
private struct ScalarTable<Value: Sendable>: @unchecked Sendable {
    /// Values for ASCII, indexed by code point.
    private let ascii: UnsafeBufferPointer<Value?>
    /// The other scalars in ascending order, and their values at the same indexes.
    private let scalars: UnsafeBufferPointer<Unicode.Scalar>
    private let values: UnsafeBufferPointer<Value>

    init(_ table: [Unicode.Scalar: Value]) {
        let others = table.filter { !$0.key.isASCII }.sorted { $0.key < $1.key }
        ascii = Self.permanent((0..<128).map { table[Unicode.Scalar(UInt8($0))] })
        scalars = Self.permanent(others.map(\.key))
        values = Self.permanent(others.map(\.value))
    }

    private static func permanent<Element>(_ elements: [Element]) -> UnsafeBufferPointer<Element> {
        let buffer = UnsafeMutableBufferPointer<Element>.allocate(capacity: elements.count)
        _ = buffer.initialize(fromContentsOf: elements)
        return UnsafeBufferPointer(buffer)
    }

    subscript(scalar: Unicode.Scalar) -> Value? {
        if scalar.isASCII { return ascii[Int(scalar.value)] }
        var low = 0
        var high = scalars.count
        while low < high {
            let middle = (low + high) / 2
            if scalars[middle] < scalar { low = middle + 1 } else { high = middle }
        }
        return low < scalars.count && scalars[low] == scalar ? values[low] : nil
    }
}

/// Lookup tables built once from `Mark` and `Alphabet`.
private struct Tables: Sendable {
    static let shared = Tables()

    /// Punctuation and symbol ranks, the byte after `Class.punctuationOrSymbol`.
    let markRanks: ScalarTable<UInt8>
    let letters: ScalarTable<LetterEncoding>

    private init() {
        // Each table's ranks have to stay below the byte that follows its band, or two kinds of
        // character would share ranks without any error.
        precondition(Mark.punctuation.unicodeScalars.count < Mark.otherPunctuation)
        precondition(
            Mark.otherPunctuation + UInt8(Mark.symbols.unicodeScalars.count) < Mark.otherSymbol)
        for order in [Alphabet.latin, Alphabet.cyrillic, Alphabet.arabic] {
            precondition(order.unicodeScalars.count < Alphabet.unlisted)
        }

        var markRanks: [Unicode.Scalar: UInt8] = [:]
        for (index, scalar) in Mark.punctuation.unicodeScalars.enumerated() {
            markRanks[scalar] = 0x01 + UInt8(index)
        }
        for (index, scalar) in Mark.symbols.unicodeScalars.enumerated() {
            markRanks[scalar] = Mark.otherPunctuation + 1 + UInt8(index)
        }

        var letters: [Unicode.Scalar: [UInt8]] = [:]
        func add(_ order: String, _ characterClass: UInt8, _ spellings: [Unicode.Scalar: String]) {
            for (index, scalar) in order.unicodeScalars.enumerated() {
                letters[scalar] = [characterClass, 0x01 + UInt8(index)]
            }
            for (scalar, spelling) in spellings {
                letters[scalar] = spelling.unicodeScalars.flatMap { letters[$0]! }
            }
        }
        add(Alphabet.latin, Class.latin, Alphabet.latinSpellings)
        add(Alphabet.cyrillic, Class.cyrillic, Alphabet.cyrillicSpellings)
        add(Alphabet.arabic, Class.arabic, [:])

        self.markRanks = ScalarTable(markRanks)
        self.letters = ScalarTable(letters.mapValues(LetterEncoding.init))
    }
}

/// The second byte of a kana or Hangul character.
private enum Syllabary {
    /// The kana iteration marks ゝ and ゞ, then the long-vowel mark ー, sort before all kana.
    static let iterationMark: UInt8 = 0x01
    static let longVowelMark: UInt8 = 0x02
    /// A Hangul syllable's final consonant sorts before any following syllable: 각 before 가나.
    static let finalConsonant: UInt8 = 0x01
    static let other: UInt8 = 0x03
}

private struct Builder {
    var bytes: [UInt8] = []
    private let tables = Tables.shared
    /// Where the digit count of the run in progress is.
    private var digitCountIndex: Int?
    /// The last letter written from `Alphabet`, while only combining marks have followed it.
    private var lastLetter: (scalar: Unicode.Scalar, encodingCount: Int)?

    mutating func append(_ scalar: Unicode.Scalar) {
        if scalar.isASCII {
            appendASCII(scalar)
            return
        }
        let properties = scalar.properties
        switch properties.generalCategory {
        case .decimalNumber:
            // `numericValue` is 0–9 for every decimal digit, whatever the script.
            appendDigit(UInt8(properties.numericValue!))
        case .nonspacingMark, .enclosingMark, .format:
            if let last = lastLetter, let letter = Alphabet.composed(last.scalar, scalar) {
                bytes.removeLast(last.encodingCount)
                appendLetter(letter)
            }
        case .spaceSeparator, .lineSeparator, .paragraphSeparator, .control:
            appendUTF8(Class.whitespace, scalar)
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
            .initialPunctuation, .finalPunctuation, .otherPunctuation:
            if scalar == Mark.ellipsis {
                for _ in 0..<3 { appendASCII(Mark.period) }
            } else if let rank = tables.markRanks[scalar] {
                appendRanked(Class.punctuationOrSymbol, rank)
            } else {
                appendUTF8(Class.punctuationOrSymbol, Mark.otherPunctuation, scalar)
            }
        case .mathSymbol, .modifierSymbol, .otherSymbol:
            if let rank = tables.markRanks[scalar] {
                appendRanked(Class.punctuationOrSymbol, rank)
            } else {
                appendUTF8(Class.punctuationOrSymbol, Mark.otherSymbol, scalar)
            }
        case .currencySymbol:
            appendUTF8(Class.punctuationOrSymbol, Mark.currency, scalar)
        case .letterNumber, .otherNumber:
            appendUTF8(Class.otherNumber, scalar)
        case .privateUse, .surrogate, .unassigned:
            appendUTF8(Class.unassigned, scalar)
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .spacingMark:
            appendLetter(scalar)
        @unknown default:
            appendUTF8(Class.unassigned, scalar)
        }
    }

    private mutating func appendASCII(_ scalar: Unicode.Scalar) {
        let value = Int(scalar.value)
        switch scalar {
        case "0"..."9":
            appendDigit(UInt8(value - 0x30))
        case "a"..."z":
            let encoding = tables.letters[scalar]!
            appendEncoding(encoding)
            lastLetter = (scalar, encoding.count)
        case "$":
            appendUTF8(Class.punctuationOrSymbol, Mark.currency, scalar)
        default:
            if let rank = tables.markRanks[scalar] {
                appendRanked(Class.punctuationOrSymbol, rank)
            } else {
                // Space and control characters; case folding has already turned A–Z into a–z.
                appendUTF8(Class.whitespace, scalar)
            }
        }
    }

    private mutating func appendLetter(_ scalar: Unicode.Scalar) {
        if let encoding = tables.letters[scalar] {
            appendEncoding(encoding)
            lastLetter = (scalar, encoding.count)
            return
        }
        switch scalar.value {
        case 0xC0...0x2FF, 0x1D00...0x1DBF, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF,
            0xAB30...0xAB6F:
            appendUTF8(Class.latin, Alphabet.unlisted, scalar)
        case 0x370...0x3FF, 0x1F00...0x1FFF:
            appendUTF8(Class.greek, scalar)
        case 0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            appendUTF8(Class.cyrillic, Alphabet.unlisted, scalar)
        case 0x10A0...0x10FF, 0x1C90...0x1CBF, 0x2D00...0x2D2F:
            appendUTF8(Class.georgian, scalar)
        case 0x530...0x58F, 0xFB13...0xFB17:
            appendUTF8(Class.armenian, scalar)
        case 0x590...0x5FF, 0xFB1D...0xFB4F:
            appendUTF8(Class.hebrew, hebrewNonFinal(scalar))
        case 0x640:
            // Tatweel stretches the joining line between Arabic letters; collation ignores it.
            return
        case 0x600...0x6FF, 0x750...0x77F, 0x8A0...0x8FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            appendUTF8(Class.arabic, Alphabet.unlisted, scalar)
        case 0x11A8...0x11FF, 0xD7CB...0xD7FF:
            appendUTF8(Class.hangul, Syllabary.finalConsonant, scalar)
        case 0x1100...0x11A7, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7CA:
            appendUTF8(Class.hangul, Syllabary.other, scalar)
        case 0x309D, 0x30FD:
            appendRanked(Class.kana, Syllabary.iterationMark)
        case 0x30FC:
            appendRanked(Class.kana, Syllabary.longVowelMark)
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0x1B000...0x1B16F:
            appendUTF8(Class.kana, Syllabary.other, hiraganaFullSize(scalar))
        case 0x3100...0x312F, 0x31A0...0x31BF:
            appendUTF8(Class.bopomofo, scalar)
        case 0x2E80...0x2FDF, 0x3005, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
            0x20000...0x3FFFF:
            appendUTF8(Class.han, scalar)
        default:
            appendUTF8(Class.otherLetter, scalar)
        }
    }

    /// Katakana and small kana sort with the full-size hiragana they spell.
    private func hiraganaFullSize(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        var value = scalar.value
        if (0x30A1...0x30F6).contains(value) { value -= 0x60 }
        switch value {
        case 0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x3063, 0x3083, 0x3085, 0x3087, 0x308E:
            value += 1  // ぁぃぅぇぉっゃゅょゎ
        case 0x3095: value = 0x304B  // ゕ
        case 0x3096: value = 0x3051  // ゖ
        default: break
        }
        return Unicode.Scalar(value)!
    }

    /// Final forms sort with the letter they end: ך with כ.
    private func hebrewNonFinal(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0x5DA, 0x5DD, 0x5DF, 0x5E3, 0x5E5: Unicode.Scalar(scalar.value + 1)!
        default: scalar
        }
    }

    /// Writes a digit run as its digit count without leading zeros, then those digits. Comparing
    /// the count first orders runs by value without padding every run to the longest possible
    /// length.
    private mutating func appendDigit(_ digit: UInt8) {
        if digitCountIndex == nil {
            beginCharacter()
            bytes.append(Class.digitRun)
            digitCountIndex = bytes.count
            bytes.append(0)
        }
        let countIndex = digitCountIndex!
        if bytes[countIndex] == 0 && digit == 0 { return }
        // A file name is at most 255 bytes, so its digit runs fit a one-byte count.
        precondition(bytes[countIndex] < 255, "a run of over 255 digits is longer than a file name")
        bytes[countIndex] += 1
        bytes.append(digit)
    }

    /// Ends any digit run before the next character is written.
    private mutating func beginCharacter() {
        digitCountIndex = nil
        lastLetter = nil
    }

    private mutating func appendEncoding(_ encoding: LetterEncoding) {
        beginCharacter()
        withUnsafeBytes(of: encoding.bytes) { bytes.append(contentsOf: $0.prefix(encoding.count)) }
    }

    private mutating func appendRanked(_ characterClass: UInt8, _ rank: UInt8) {
        beginCharacter()
        bytes.append(characterClass)
        bytes.append(rank)
    }

    private mutating func appendUTF8(_ characterClass: UInt8, _ scalar: Unicode.Scalar) {
        beginCharacter()
        bytes.append(characterClass)
        bytes.append(contentsOf: UTF8.encode(scalar)!)
    }

    private mutating func appendUTF8(
        _ characterClass: UInt8, _ prefix: UInt8, _ scalar: Unicode.Scalar
    ) {
        beginCharacter()
        bytes.append(characterClass)
        bytes.append(prefix)
        bytes.append(contentsOf: UTF8.encode(scalar)!)
    }
}
