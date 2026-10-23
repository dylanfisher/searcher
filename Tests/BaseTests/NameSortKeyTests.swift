import Foundation
import Testing

@testable import Base

/// Names Finder has to order: accented Latin, CJK, Cyrillic, Arabic, Hebrew, Greek, emoji with
/// ZWJ sequences and skin tones, punctuation and leading dots, long digit runs, leading zeros and
/// full-width digits. Precomposed and decomposed spellings both appear, because names read from
/// HFS+ and SMB volumes often arrive decomposed.
let corpus: [String] = [
    // Plain and accented Latin.
    "a", "A", "b", "B", "z", "Z", "ab", "apple", "Apple", "APPLE", "zebra", "Zebra",
    "résumé", "re\u{301}sume\u{301}", "resume", "Resume", "RESUME", "café", "cafe", "Café",
    "école", "e\u{301}cole", "ecole", "Ångström", "angstrom", "Zürich", "zurich", "naïve", "naive",
    "über", "uber", "Über", "straße", "strasse", "Straße", "strasze", "œuvre", "oeuvre", "Æsir",
    "aesir", "Ærø", "ørsted", "Ørsted", "orsted", "Łódź", "lodz", "Dvořák", "dvorak", "Škoda",
    "skoda", "ñandú", "nandu", "façade", "facade", "Þór", "thor", "tor", "Đorđe", "djordje",
    "İstanbul", "istanbul", "ıspanak", "ispanak", "ĳs", "ijs", "ﬁle", "file", "Ｆｉｌｅ",
    // Greek.
    "Ελλάδα", "ελλάδα", "αλφα", "ωμέγα", "Σίσυφος", "σοφός", "Ωμέγα",
    // Cyrillic, including Ukrainian and Serbian letters outside the Russian alphabet.
    "москва", "Москва", "МОСКВА", "ёлка", "елка", "Ёж", "ежевика", "яблоко", "Ярослав", "йогурт",
    "иван", "Иван", "Йошкар-Ола", "Київ", "Киев", "їжак", "ізюм", "єнот", "ехо", "ґанок", "гора",
    "Љубљана", "Ђорђе", "Џон", "ћерка", "јабука", "кафа",
    // Hebrew, with final and non-final forms.
    "עברית", "שלום", "ירושלים", "אבא", "ספר", "מלך", "מלכה", "מלכים",
    // Arabic, with hamza and madda letters, tatweel and Persian letters.
    "العربية", "مرحبا", "القاهرة", "بيت", "مدرسة", "باب", "أحمد", "إسلام", "آمنة", "ابن", "مؤمن",
    "موز", "مو", "سائل", "سيارة", "كتـاب", "پدر", "بلد", "چای", "جمل", "ژاله", "زيت", "کتاب",
    "كتاب",
    "گل", "یک", "يوم",
    // CJK: Han, Hangul, kana in full and half width, small kana, iteration and long-vowel marks.
    "日本語", "中文", "漢字", "東京", "北京", "龥", "𠀀", "한국어", "서울", "가나다", "각", "가",
    "가 나", "ひらがな", "カタカナ", "ｶﾀｶﾅ", "がっこう", "かつお", "コーヒー", "こおり", "コアラ",
    "いすゞ", "いすず", "ぁa", "あb",
    // Emoji, including ZWJ sequences, skin tones and variation selectors.
    "😀", "😀 smile", "👍", "👍🏽", "👍🏿", "👨‍👩‍👧", "👨", "👩‍💻", "🏳️‍🌈", "🎉 party", "❤️", "⭐",
    // Punctuation, symbols and leading dots.
    ".hidden", ".Hidden", ".DS_Store", ".git", "..double", "_underscore", "__init__.py", "-dash",
    "#hash", "(paren)", "[bracket]", "{brace}", "~tilde", "!bang", "@at", "&and", "%percent",
    "+plus", "=equals", "$dollar", "€euro", "'quote", "\"double quote\"", "a b", "a-b", "a_b",
    "a.b", "a,b", "a;b", "a.txt", "a 1.txt", "a1.txt", "a2.txt", "a10.txt", "a (1)", "a (2)",
    "a (10)", "a copy", "a – b", "a — b", "a…", "a...", "a\u{200B}b", "Dylan's", "Dylan’s",
    "«quoted»", "“quoted”", "a • b", "°C", "©2024", "×", "½ cup",
    // Digit runs: leading zeros, runs of 20 and more digits, dates and versions.
    "0", "00", "000", "1", "01", "001", "007", "2", "9", "10", "100", "file1", "file01",
    "file001", "file2", "file9", "file10", "file100", "x12345678901234567890",
    "x12345678901234567891", "x123456789012345678901", "x99999999999999999999",
    "x100000000000000000000", "x0000000000000000000000001", "IMG_0001.jpg", "IMG_0002.jpg",
    "IMG_0010.jpg", "IMG_10.jpg", "2023-12-31", "2024-01-05", "2024-1-5", "v1.2.3", "v1.2.10",
    "v1.10.0", "Track 1", "Track 01", "Track 10", "1.5", "1.10",
    // Full-width and other-script digits, and numbers that aren't decimal digits.
    "１２３", "123", "file１０", "file２", "ｆｉｌｅ２", "０", "٣", "٣٠", "५", "½", "x²", "x3",
]

/// Corpus pairs whose key order differs from `localizedStandardCompare` on purpose, grouped by
/// reason. Each pair is in `localizedStandardCompare` order.
struct KeptMismatch {
    let reason: String
    let pairs: [[String]]
}

/// Every kept mismatch in the corpus and among `tableNames`. M0.11 copies these into
/// `docs/decisions/0004-listing-view.md`.
let keptMismatches: [KeptMismatch] = [
    KeptMismatch(
        reason: """
            localizedStandardCompare stops ordering digit runs by value once they pass \
            UInt64.max (18446744073709551615): it puts x99999999999999999999 before \
            x12345678901234567890. The key orders runs of any length by value.
            """,
        pairs: [
            ["x99999999999999999999", "x12345678901234567890"],
            ["x99999999999999999999", "x12345678901234567891"],
            ["x100000000000000000000", "x12345678901234567890"],
            ["x100000000000000000000", "x12345678901234567891"],
        ]),
    KeptMismatch(
        reason: """
            The key orders Han characters by code point. localizedStandardCompare orders them by \
            radical and stroke count, which files characters outside the main CJK block, such \
            as 𠀀 (U+20000, radical 一), among the main block's characters instead of after them. \
            Matching it would need the Unihan radical-stroke table.
            """,
        pairs: [
            ["𠀀", "中文"], ["𠀀", "北京"], ["𠀀", "日本語"], ["𠀀", "東京"], ["𠀀", "漢字"],
            ["𠀀", "龥"],
        ]),
    KeptMismatch(
        reason: """
            Not an order difference: ０, 00 and 000 share a key, as 0, 00 and 000 do, because \
            width and leading zeros are both folded. The test accepts a shared key only when \
            Foundation's numeric compare calls the names equal, and that compare doesn't fold \
            a full-width zero run together with an ASCII one.
            """,
        pairs: [["０", "00"], ["０", "000"]]),
    KeptMismatch(
        reason: """
            localizedStandardCompare puts a name first when it is a prefix of the other after \
            canonical decomposition, before collating. آ, أ, إ, ؤ and ئ decompose to ا, و or ي \
            plus a mark, so ا sorts before آ and مو before مؤمن, although the root order puts \
            those letters before ا (آب before اب, مؤمن before موب). The key follows the root \
            order.
            """,
        pairs: [
            ["ا", "آ"], ["ا", "أ"], ["ا", "إ"], ["و", "ؤ"], ["ي", "ئ"], ["مو", "مؤمن"],
        ]),
]

/// The locale the expected order is taken in. The key follows the root collation order, which
/// English uses; `localizedStandardCompare` itself uses the machine's locale, and a locale with
/// its own order (Swedish puts å after z, for example) would fail the test.
let finderLocale = Locale(identifier: "en_US")

/// `localizedStandardCompare` in `finderLocale`, with the options it documents.
func finderAscending(_ a: String, _ b: String) -> Bool {
    let options: String.CompareOptions = [
        .caseInsensitive, .numeric, .widthInsensitive, .forcedOrdering,
    ]
    return a.compare(b, options: options, range: nil, locale: finderLocale) == .orderedAscending
}

/// Whether `localizedStandardCompare` would call two names equal if it didn't force an order:
/// equal up to case, accents, width and leading zeros. Only such names may share a key.
func foldedEqual(_ a: String, _ b: String) -> Bool {
    let options: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric,
    ]
    return a.compare(b, options: options, range: nil, locale: finderLocale) == .orderedSame
}

/// Pairs whose key order differs from `localizedStandardCompare`, as (lower, higher) by
/// `localizedStandardCompare`.
func mismatches(in names: [String]) -> Set<[String]> {
    let keys = names.map(NameSortKey.init)
    var found: Set<[String]> = []
    for i in names.indices {
        for j in names.indices where i < j {
            let (a, b) = (names[i], names[j])
            let finderAscending = finderAscending(a, b)
            let ordered = finderAscending ? [a, b] : [b, a]
            if keys[i] == keys[j] {
                if !foldedEqual(a, b) { found.insert(ordered) }
            } else if (keys[i] < keys[j]) != finderAscending {
                found.insert(ordered)
            }
        }
    }
    return found
}

/// Checks every pair of `names`, allowing exactly the kept mismatches among them.
func expectKeyOrderMatchesLocalizedStandardCompare(_ names: [String]) {
    let found = mismatches(in: names)
    let present = Set(names)
    let kept = Set(keptMismatches.flatMap(\.pairs).filter { $0.allSatisfy(present.contains) })
    let unexpected = found.subtracting(kept).sorted { $0.lexicographicallyPrecedes($1) }
    let stale = kept.subtracting(found).sorted { $0.lexicographicallyPrecedes($1) }
    #expect(unexpected.isEmpty, "key order differs from localizedStandardCompare: \(unexpected)")
    #expect(stale.isEmpty, "kept mismatches that no longer happen: \(stale)")
}

@Test func keyOrderMatchesLocalizedStandardCompare() {
    expectKeyOrderMatchesLocalizedStandardCompare(corpus)
}

/// Every character in the key's rank tables, and every letter a spelling table maps, as a name of
/// its own, so a misplaced table entry shows up as a mismatched pair.
let tableNames: [String] = {
    let tables = [
        Mark.punctuation, Mark.symbols, Alphabet.latin, Alphabet.cyrillic, Alphabet.arabic,
    ]
    let spellings = Alphabet.latinSpellings.merging(Alphabet.cyrillicSpellings) { $1 }
    var names = tables.flatMap { $0.unicodeScalars.map(String.init) }
    names += spellings.flatMap { [String($0.key), $0.value] }
    names += [String(Mark.ellipsis), "..."]
    var seen: Set<String> = []
    return names.filter { seen.insert($0).inserted }
}()

@Test func rankTablesMatchLocalizedStandardCompare() {
    expectKeyOrderMatchesLocalizedStandardCompare(tableNames)
}

/// Checks that pinning the locale doesn't hide a difference from what Finder shows on an English
/// machine.
@Test(.enabled(if: Locale.current.language.languageCode == "en"))
func pinnedOrderMatchesLocalizedStandardCompare() {
    let names = corpus + tableNames
    var differing: [[String]] = []
    for a in names {
        for b in names where a != b {
            if (a.localizedStandardCompare(b) == .orderedAscending) != finderAscending(a, b) {
                differing.append([a, b])
            }
        }
    }
    #expect(differing.isEmpty, "\(differing)")
}

@Test func digitRunsCompareByValue() {
    let ascending = ["file2", "file10", "x99999999999999999999", "x100000000000000000000"]
    let keys = ascending.map(NameSortKey.init)
    #expect(keys == keys.sorted())
    #expect(NameSortKey("file007") == NameSortKey("file7"))
}

@Test func foldDropsCaseAccentsAndWidth() {
    #expect(utf8(NameSortKey.fold("Ünïcode Ｆｉｌｅ")) == utf8(NameSortKey.fold("unicode file")))
    #expect(utf8(NameSortKey.fold("unicode file")) == utf8("unicode file"))
    #expect(utf8(NameSortKey.fold("Re\u{301}sumé")) == utf8("resume"))
}

@Test func foldKeepsLettersTheRootOrderKeepsApart() {
    // Canonical decomposition splits й into и and a breve; the fold puts them back together.
    #expect(utf8(NameSortKey.fold("Йогурт")) == utf8("йогурт"))
    #expect(utf8(NameSortKey.fold("и\u{306}")) == utf8("й"))
    #expect(utf8(NameSortKey.fold("أحمد")) == utf8("أحمد"))
}

@Test func keyFollowsTheFold() {
    for name in corpus {
        #expect(NameSortKey(name) == NameSortKey(NameSortKey.fold(name)), "\(name)")
    }
}

@Test func parallelBuildMatchesSerialBuild() {
    // Enough names for several chunks, with a remainder so the last chunk is short.
    let names = (0..<20_011).map { "\(corpus[$0 % corpus.count]) \($0)" }
    let built = NameSortKey.foldedNamesAndKeys(for: names)
    #expect(built.keys == names.map(NameSortKey.init))
    #expect(built.foldedNames.map(utf8) == names.map { utf8(NameSortKey.fold($0)) })
}

@Test func parallelBuildHandlesFewNames() {
    let none = NameSortKey.foldedNamesAndKeys(for: [])
    #expect(none.keys.isEmpty && none.foldedNames.isEmpty)
    let two = NameSortKey.foldedNamesAndKeys(for: ["B", "a"])
    #expect(two.keys == [NameSortKey("B"), NameSortKey("a")])
    #expect(two.foldedNames == ["b", "a"])
}

/// A string's bytes, since `String` equality treats canonically equivalent strings as equal.
private func utf8(_ string: String) -> [UInt8] {
    Array(string.utf8)
}
