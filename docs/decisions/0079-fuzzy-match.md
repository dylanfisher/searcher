# 0079. Fuzzy match: a Swift alignment over folded bytes, initials first, one word over many

- **Date:** 2026-10-23
- **Status:** accepted

## Context

The palette (M5a.6, M5a.7) matches a typed query against up to 50k candidates on every key and
shows the best 50 with their matched letters highlighted. B11 gives a key 50 ms to the frame; the
matcher's part is benched on 50k W3 paths. Matching must ignore case, width and accents as
type-to-select and filtering do, with the one fold in `NameSortKey.fold`
([0028](0028-folded-names.md)). The plan asks that "dl" find "Downloads" at the D and the l, and
that "prj1" rank "Project 1" above "pr-junk-1". Review against file-browser names asked for
initials to win: "gh" should find "GitHub" before "ghost", "mvd" "my-video-downloads" before
"mvdir", and "dl" "Downloads" before "Deleted Items".

## Decision

- **Scoring.** The query's letters must appear in order. Each matched letter earns 10 at the
  start of the text or of a path component (after `/`), 8 at a word start (after a space or
  punctuation, or a capital after a lowercase letter), and 6 right after the previous matched
  letter. Equal scores rank the shorter text first, then the earlier candidate.
  - **A gap inside a word** costs a flat 3, whatever its length: where an abbreviation takes a
    word's letters from says little, so "dl" scores "Downloads" and "Deleted Items" alike and the
    shorter name wins.
  - **A gap into a later word** costs 3, plus 1 per skipped byte, plus 10 for the new word. The
    new-word cost outweighs the word-start bonus, so letters kept in one word beat letters spread
    over word starts: "prj" reads as an abbreviation of "Project", not of "pr-junk".
  - **An initials chain** is the exception: while every matched letter so far is the first
    letter of a word in one path component, each keeps its word-start bonus with no gap or
    new-word cost. "gh" scores 18 in "GitHub" against 16 for the run in "ghost", and "mvd" 26 in
    "my-video-downloads" against 22 in "mvdir". The chain stops at a `/`: path components are
    separate names, so "dl" in "Desktop/lib" isn't a chain and "Downloads" ranks first. Once a
    letter falls outside the chain, the rest score by the rules above, so "pr-junk-1" gets no
    chain for "prj1".
- **Best alignment.** A dynamic program over query × candidate bytes finds the best-scoring
  placement, not the first, so "doc" against "old/docs" highlights "docs". It keeps two tables,
  the best score and the best initials-chain score at each cell. Each query byte is only tried
  between the first and last place it can go (a greedy scan from each end), and the gap and chain
  transitions keep running maxima, so a row costs one pass. The scan from the left is also the
  reject: a candidate missing a letter is dropped in one pass with no table. A test checks the
  scores against a brute-force search of every placement on 20,000 random texts.
- **Folded bytes.** A `Candidate` is prepared once: the folded text as one `[UInt16]`, each unit
  a byte plus its position (in a word, word start, component start, separator). An ASCII text
  folds with `NameSortKey.fold` in one call and its offsets line up with the original. A text
  with other characters is folded a character at a time with the same function, keeping each
  folded byte's character offset in an `[Int32]` so the match's ranges point at the original
  characters ("e" highlights the "é" of "Résumé"). Matching is per byte, but a UTF-8
  continuation byte in the query must directly follow its lead byte and adds nothing, so a
  character matches whole and scores as one letter.
- **Allocation.** `best(_:limit:)` keeps its tables in one scratch per call, grown to the longest
  candidate, so after the first few candidates scoring allocates nothing. The top `limit` sit in
  a sorted array with binary insertion; ranges, the only per-result allocation, are built for
  those alone. `score(_:)` and `match(_:)` on their own allocate their tables per call. A
  `withUnsafeTemporaryAllocation` was the first choice, but it stays on the stack only up to
  1,024 bytes, and a 6-letter query against a 45-byte W3 path needs 1,080 for one table.
- **Bench.** Against B11: each key of "srcmap" over 50k W3 paths, the last key of the 12-letter
  "nodpkgsrcmap" (a key's cost grows with the query's length), and preparing the 50k
  `Candidate`s, which the palette pays once on opening rather than per key. If preparation misses
  B11 it becomes report-only and this record says so; it can then run off the main actor while
  the palette opens.
- **No C.** C comes only if Swift misses B11, with before and after numbers here.

## Alternatives considered

- **Greedy first match (forward then backward scan, as fzf's v1)** — rejected: it picks the
  first occurrence of a letter, so ranges and scores miss a later word start ("old/docs").
- **Word-start bonus without a new-word penalty (fzf, VS Code)** — rejected: it ranks
  "pr-junk-1" above "Project 1" for "prj1", since every letter of "pr-junk-1" sits at a word
  start, and "Desktop/lib" above "Downloads" for "dl".
- **A gap cost growing inside a word** — rejected: "Deleted Items" ranked above "Downloads" for
  "dl" by one skipped letter.
- **A chain when only the previous letter was a word start** — rejected: "pr-junk-1" then chains
  "j" to "1" and ranks above "Project 1" for "prj1".
- **A chain across path components** — rejected: it ranks "Desktop/lib" above "Downloads".
- **Match on `Character` or unicode scalars** — rejected: the folded text is canonically
  decomposed, and comparing bytes is what type-to-select does; scalar arrays would cost four
  bytes a scalar per candidate for the same answers.
- **Fold the whole text and map back by re-folding prefixes** — rejected: per-character folding
  gives the map directly, and only non-ASCII texts pay for it.
- **Rescore only the previous key's matches when the query grows** — left to the palette:
  the matcher has no state between keys, and the bench times the full rescore every key.

## Consequences

`FuzzyMatcher` is a value with no state between keys, so the palette can score sources on any
thread. A candidate costs 2 bytes a folded byte plus its array header, and 4 more bytes a byte
when it isn't ASCII. Camel-case word starts are only seen in ASCII texts. "ss" ties "Sessions"
with "Screenshots", since both start with S and skip letters inside one word, and the shorter
"Sessions" ranks first; a name the user opens often has to win through frecency in M5a.6. An
initials chain beats an exact prefix: "ab" ranks "a-b" above "ab". The scores are plain integers
for one query; M5a.6 combines them with frecency and kind order. If B11 misses on real candidate
lists, the next steps are splitting `best` over cores and the incremental rescore above, before
C.
