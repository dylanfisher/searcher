import Testing

@testable import Base

/// The texts of `candidate`'s matched ranges.
private func matchedTexts(_ query: String, _ candidate: String) -> [String]? {
    let text = FuzzyMatcher.Candidate(candidate)
    return FuzzyMatcher(query).match(text)?.ranges.map { String(candidate[$0]) }
}

/// `candidates` ranked by `query`, best first, as texts.
private func ranked(_ query: String, _ candidates: [String]) -> [String] {
    let prepared = candidates.map(FuzzyMatcher.Candidate.init)
    return FuzzyMatcher(query).best(prepared, limit: candidates.count).map { candidates[$0.index] }
}

@Test func dlMatchesDownloadsAtTheDAndTheL() throws {
    let candidate = "Downloads"
    let match = try #require(FuzzyMatcher("dl").match(FuzzyMatcher.Candidate(candidate)))
    let d = candidate.startIndex
    let l = candidate.index(d, offsetBy: 4)
    #expect(match.ranges == [d..<candidate.index(after: d), l..<candidate.index(after: l)])
}

@Test func prj1RanksProject1AbovePrJunk1() {
    #expect(ranked("prj1", ["pr-junk-1", "Project 1"]) == ["Project 1", "pr-junk-1"])
}

@Test(arguments: ["dxl", "dlz", "x", "downloadss"])
func aMissingLetterIsNoMatch(query: String) {
    #expect(FuzzyMatcher(query).match(FuzzyMatcher.Candidate("Downloads")) == nil)
    #expect(FuzzyMatcher(query).score(FuzzyMatcher.Candidate("Downloads")) == nil)
}

@Test func lettersOutOfOrderAreNoMatch() {
    #expect(FuzzyMatcher("ld").match(FuzzyMatcher.Candidate("Downloads")) != nil)
    #expect(FuzzyMatcher("sd").match(FuzzyMatcher.Candidate("Downloads")) == nil)
}

@Test func anAccentedQueryMatchesThePlainLetterAndTheReverse() {
    #expect(matchedTexts("é", "Resume") == ["e"])
    #expect(matchedTexts("e", "Résumé") == ["é"])
    #expect(matchedTexts("rsm", "Résumé") == ["R", "s", "m"])
}

@Test func caseAndWidthAreFolded() {
    #expect(matchedTexts("DL", "downloads") == ["d", "l"])
    #expect(matchedTexts("file", "Ｆｉｌｅ") == ["Ｆｉｌｅ"])
}

@Test func aCharacterOfSeveralBytesMatchesWhole() {
    #expect(matchedTexts("日本", "日x本") == ["日", "本"])
    // 本 is E6 9C AC. 日 starts with E6, ʜ ends with 9C and ʬ with AC: the bytes of 本
    // in order, but no 本.
    #expect(matchedTexts("本", "日ʜʬ") == nil)
}

@Test func aLetterInsideAFoldedLigatureHighlightsTheLigature() {
    #expect(matchedTexts("f", "ﬁle") == ["ﬁ"])
    #expect(matchedTexts("il", "ﬁle") == ["ﬁl"])
}

@Test func aPrefixOnAccentedTextHighlightsItsCharacters() {
    #expect(matchedTexts("rés", "Résumé") == ["Rés"])
}

@Test func aRunIsOneRange() {
    #expect(matchedTexts("down", "My Downloads") == ["Down"])
}

@Test func rangesFollowTheBestAlignmentNotTheFirstLetters() {
    // The first "d" and "o" are in "old"; the word starts of "docs" score higher.
    #expect(matchedTexts("doc", "old/docs") == ["doc"])
}

@Test func anEmptyQueryMatchesEverythingWithNoRanges() throws {
    let match = try #require(FuzzyMatcher("").match(FuzzyMatcher.Candidate("Downloads")))
    #expect(match.ranges.isEmpty)
    #expect(match.score == FuzzyMatcher("").score(FuzzyMatcher.Candidate("Downloads")))
}

@Test func scoreAgreesWithMatch() {
    let candidates = ["Project 1", "pr-junk-1", "projects/searcher/docs", "Ünïcødé-1"]
    for query in ["prj1", "p", "pro", "u1", "doc"] {
        let matcher = FuzzyMatcher(query)
        for text in candidates {
            let candidate = FuzzyMatcher.Candidate(text)
            #expect(matcher.score(candidate) == matcher.match(candidate)?.score, "\(query) \(text)")
        }
    }
}

@Test func bestKeepsTheLimitAndDropsNonMatches() {
    let candidates = ["docs", "Documents", "dictionary", "my-documents", "zzz"]
    let best = FuzzyMatcher("doc").best(candidates.map(FuzzyMatcher.Candidate.init), limit: 2)
    #expect(best.map { candidates[$0.index] } == ["docs", "Documents"])
    let all = FuzzyMatcher("doc").best(candidates.map(FuzzyMatcher.Candidate.init), limit: 10)
    #expect(all.map { candidates[$0.index] } == ["docs", "Documents", "my-documents"])
}

/// The golden list: a fixed set of candidates ranks in this fixed order for "doc". A prefix run
/// ranks first, shorter texts first among equal scores; a run at a later word or path component
/// start comes next; letters spread over several words come last.
@Test func aFixedListRanksInAFixedOrder() {
    let golden = [
        "docs",
        "Documents",
        "projects/searcher/docs",
        "my-documents",
        "dot-com",
        "Downloads/c",
        "Desktop/old-code",
    ]
    let shuffled = [
        golden[5], golden[2], "dictionary", golden[6], golden[0], golden[4], golden[3], golden[1],
    ]
    #expect(ranked("doc", shuffled) == golden)
}

/// `query`'s score against `candidate`.
private func score(_ query: String, _ candidate: String) -> Int? {
    FuzzyMatcher(query).score(FuzzyMatcher.Candidate(candidate))
}

/// Folder and app names a file-browser palette sees: initials of one name beat a prefix run of
/// one or two letters, and from three letters the prefix wins.
@Test func initialsOfOneNameRankAboveAShortPrefixRun() {
    #expect(
        ranked("gh", ["ghost", "Library/Highlights", "github", "GitHub"])
            == ["GitHub", "ghost", "github", "Library/Highlights"])
    #expect(
        ranked("mvd", ["Movies/Downloads", "my-video-downloads"])
            == ["my-video-downloads", "Movies/Downloads"])
    #expect(
        ranked("mvd", ["mvdir", "my-video-downloads"]) == ["mvdir", "my-video-downloads"])
    #expect(ranked("mv", ["mvdir", "my-video-downloads"]) == ["my-video-downloads", "mvdir"])
}

@Test func initialsInDifferentPathComponentsAreNotAChain() {
    #expect(ranked("dl", ["Desktop/lib", "Downloads"]) == ["Downloads", "Desktop/lib"])
}

@Test func aGapInsideAWordCostsTheSameWhateverItsLength() {
    #expect(ranked("dl", ["Deleted Items", "Downloads"]) == ["Downloads", "Deleted Items"])
    #expect(score("ab", "axb") == score("ab", "axxxxb"))
}

/// Sessions has the same leading S and a shorter word, so it ties Screenshots and ranks first by
/// length; only frecency (M5a.6) can put Screenshots first. Both beat a match inside a word.
@Test func ssRanksScreenshotsAboveAssets() {
    #expect(
        ranked("ss", ["assets", "Sessions", "Screenshots"])
            == ["Sessions", "Screenshots", "assets"])
}

@Test func typingANameRanksThatNameFirst() {
    #expect(ranked("ab", ["a-b", "ab"]) == ["ab", "a-b"])
    #expect(ranked("down", ["d-o-w-n", "Downloads"]) == ["Downloads", "d-o-w-n"])
    // A whole component beats an initials chain of longer words, and a prefix of a longer name.
    #expect(ranked("ab", ["ax-bx", "abc", "ab"]) == ["ab", "ax-bx", "abc"])
    #expect(ranked("docs", ["dx-ox-cx-sx", "projects/docs"]) == ["projects/docs", "dx-ox-cx-sx"])
    #expect(matchedTexts("docs", "docs/x/docs") == ["docs"])
}

/// Command and folder names: a typed prefix of three or more letters beats initials, and
/// initials still win for one or two letters.
@Test func aPrefixOfThreeLettersBeatsInitials() {
    #expect(ranked("cop", ["Copy to Other Pane", "Copy"]) == ["Copy", "Copy to Other Pane"])
    #expect(
        ranked("pro", ["pdf-reader-online", "Projects/pdf-reader-online", "Projects"])
            == ["Projects", "Projects/pdf-reader-online", "pdf-reader-online"])
    #expect(
        ranked("nw", ["New Tab", "New File", "Open in New Tab", "New Window"]).first
            == "New Window")
    #expect(
        ranked("dp", ["Duplicate", "Desktop", "Toggle Dual Pane"]).first == "Toggle Dual Pane")
}

/// Scores as numbers, so a change to any bonus or penalty fails here.
@Test(arguments: [
    ("ab", "xab", 6),  // run
    ("ab", "axb", 7),  // component start, gap inside a word
    ("ab", "axxxxb", 7),
    ("b", "x-bc", 8),  // word start
    ("b", "x/bc", 10),  // component start
    ("b", "aBc", 8),  // camel case
    ("b", "ABc", 0),
    ("ab", "a-xb", -5),  // gap into a later word
    ("ab", "a-xxb", -6),
    ("ab", "ax-xx-bx", 18),  // initials chain
    ("ab", "a-xx-bx", 1),  // one-letter word, no chain
    ("ab", "x/ab", 22),  // whole component, two letters
    ("ab", "x/abc", 16),  // two-letter prefix: a run
    ("abc", "abcd", 28),  // three-letter prefix
    ("abc", "x/abc", 37),  // whole component, three letters
    ("prj1", "Project 1", 4),
    ("prj1", "pr-junk-1", 1),
    ("gh", "GitHub", 18),
    ("gh", "ghost", 16),
])
func scoresAreTheseNumbers(query: String, candidate: String, expected: Int) {
    #expect(score(query, candidate) == expected)
}

/// Pairs one point apart, so moving newWordPenalty, gapBytePenalty or gapOpenPenalty by one in
/// either direction ties them and the tie-break flips the order.
@Test func rankingsOnePointApart() {
    // newWordPenalty: 4 against 3, and 4 against 4 broken by length.
    #expect(ranked("prj1", ["pr-ju-1", "Project 1"]) == ["Project 1", "pr-ju-1"])
    #expect(ranked("prj1", ["Project 1", "pr-j-1"]) == ["pr-j-1", "Project 1"])
    #expect(ranked("ab", ["a-bc", "x-axb"]) == ["x-axb", "a-bc"])
    // gapBytePenalty: 4 against 3, the longer text first.
    #expect(ranked("ab", ["a--bc", "a-bcxx"]) == ["a-bcxx", "a--bc"])
    // gapOpenPenalty: 7 against 6, the later candidate first.
    #expect(ranked("ab", ["xab", "axb"]) == ["axb", "xab"])
}

@Test func eachBonusAndPenaltyCounts() throws {
    typealias M = FuzzyMatcher
    #expect(score("ab", "xab") == Int(M.runBonus))
    #expect(score("ab", "axb") == Int(M.componentStartBonus - M.gapOpenPenalty))
    #expect(score("b", "x-b") == Int(M.wordStartBonus))
    #expect(score("b", "x/bc") == Int(M.componentStartBonus))
    // Into a later word: the gap's bytes count, and so does the new word.
    let intoLaterWord = try #require(score("ab", "a-xb"))
    #expect(
        intoLaterWord
            == Int(
                M.componentStartBonus - M.gapOpenPenalty - 2 * M.gapBytePenalty
                    - M.newWordPenalty))
    #expect(score("ab", "a-xxb") == intoLaterWord - Int(M.gapBytePenalty))
    // An initials chain keeps each word-start bonus with no gap cost, for words of two or
    // more letters.
    #expect(score("ab", "ax-xx-bx") == Int(M.componentStartBonus + M.wordStartBonus))
    #expect(score("ab", "a-xx-bx")! < Int(M.componentStartBonus))
    #expect(
        score("ab", "x/ab")
            == Int(M.componentStartBonus + M.runBonus + 2 * M.exactComponentBonus))
}

@Test func aRunRanksAboveAGap() {
    #expect(ranked("ab", ["xaxb", "xab"]) == ["xab", "xaxb"])
}

@Test func aCapitalAfterALowercaseLetterStartsAWord() {
    #expect(ranked("b", ["abc", "aBc"]) == ["aBc", "abc"])
    #expect(score("b", "aBc") == Int(FuzzyMatcher.wordStartBonus))
    #expect(score("b", "ABc") == 0)
}

@Test func equalScoresAndLengthsKeepTheCandidateOrder() {
    #expect(ranked("ab", ["yab", "xab"]) == ["yab", "xab"])
    #expect(ranked("ab", ["xab", "yab"]) == ["xab", "yab"])
}

/// The best score over every placement of the query's bytes, computed from the rules in
/// `FuzzyMatcher`'s documentation one placement at a time: a prefix of initials in one
/// component scores its word-start bonuses, and the rest scores by runs, gaps and new words.
private func bruteForceScore(_ query: String, _ text: String) -> Int? {
    typealias M = FuzzyMatcher
    let query = Array(NameSortKey.fold(query).utf8)
    let units = FuzzyMatcher.Candidate(text).units
    guard !query.isEmpty else { return 0 }
    let byte = { (j: Int) in UInt8(truncatingIfNeeded: units[j]) }
    let position = { (j: Int) in M.Position(rawValue: UInt8(units[j] >> 8))! }
    let starts = { (j: Int) in position(j) == .wordStart || position(j) == .componentStart }
    let longWord = { (j: Int) in j + 1 < units.count && position(j + 1) == .inWord }
    let bonus = { (j: Int) -> Int in
        switch position(j) {
        case .componentStart: Int(M.componentStartBonus)
        case .wordStart: Int(M.wordStartBonus)
        case .inWord, .separator: 0
        }
    }
    let isContinuation = { (i: Int) in query[i] & 0xC0 == 0x80 }
    var best: Int?
    func score(_ placement: [Int]) {
        for i in placement.indices.dropFirst() where isContinuation(i) {
            guard placement[i] == placement[i - 1] + 1 else { return }
        }
        // The longest prefix that is an initials chain.
        var chainEnd = starts(placement[0]) && longWord(placement[0]) ? 0 : -1
        var chainScore = bonus(placement[0])
        var chainScores = [chainScore]
        if chainEnd == 0 {
            for i in placement.indices.dropFirst() {
                let (k, j) = (placement[i - 1], placement[i])
                if isContinuation(i) {
                    chainEnd = i
                } else if position(j) == .wordStart && longWord(j)
                    && !(k + 1...j).contains(where: { position($0) == .componentStart })
                {
                    chainScore += bonus(j)
                    chainEnd = i
                } else {
                    break
                }
                chainScores.append(chainScore)
            }
        }
        for split in 0...max(chainEnd, 0) {
            var total = split <= chainEnd ? chainScores[split] : bonus(placement[0])
            for i in (split + 1)..<max(split + 1, placement.count) {
                let (k, j) = (placement[i - 1], placement[i])
                if isContinuation(i) {
                    continue
                } else if j == k + 1 {
                    total += Int(M.runBonus)
                } else if !(k + 1...j).contains(where: starts) {
                    total -= Int(M.gapOpenPenalty)
                } else {
                    total +=
                        bonus(j) - Int(M.gapOpenPenalty) - Int(M.gapBytePenalty) * (j - k - 1)
                        - Int(M.newWordPenalty)
                }
            }
            best = max(best ?? total, total)
        }
    }
    func place(_ i: Int, from start: Int, _ placement: [Int]) {
        guard i < query.count else { return score(placement) }
        for j in start..<units.count where byte(j) == query[i] {
            place(i + 1, from: j + 1, placement + [j])
        }
    }
    place(0, from: 0, [])
    // The query as a prefix of a path component, or as a whole one.
    let letters = query.count { $0 & 0xC0 != 0x80 }
    let m = query.count
    for start in units.indices
    where position(start) == .componentStart && start + m <= units.count
        && (0..<m).allSatisfy({ byte(start + $0) == query[$0] })
    {
        let isWhole = start + m == units.count || byte(start + m) == UInt8(ascii: "/")
        let prefix =
            Int(M.componentStartBonus) + Int(M.runBonus) * (letters - 1)
            + (letters >= M.prefixLetters ? Int(M.prefixBonus) * letters : 0)
            + (isWhole ? Int(M.exactComponentBonus) * letters : 0)
        best = max(best ?? prefix, prefix)
    }
    return best
}

@Test func scoresAgreeWithABruteForceSearch() {
    var state: UInt64 = 42
    func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(state >> 33) % bound
    }
    let textLetters = Array("aAbBx-/ é日ab-/")
    let queryLetters = Array("abé日-/")
    for _ in 0..<20_000 {
        let text = String((0..<(1 + next(10))).map { _ in textLetters[next(textLetters.count)] })
        let query = String((0..<(1 + next(3))).map { _ in queryLetters[next(queryLetters.count)] })
        let candidate = FuzzyMatcher.Candidate(text)
        let expected = bruteForceScore(query, text)
        #expect(FuzzyMatcher(query).score(candidate) == expected, "\(query) in \(text)")
        #expect(FuzzyMatcher(query).match(candidate)?.score == expected, "\(query) in \(text)")
    }
}
