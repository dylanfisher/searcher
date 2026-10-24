import Base
import Testing

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
    // 本 is E6 9C AC. 日 starts with E6, ʜ ends with 9C and ʬ with AC: the bytes of 本 in order,
    // but no 本.
    #expect(matchedTexts("本", "日ʜʬ") == nil)
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
