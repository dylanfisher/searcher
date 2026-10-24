# 0079. Fuzzy match: a Swift alignment over folded bytes, with a penalty for each new word

- **Date:** 2026-10-23
- **Status:** accepted

## Context

The palette (M5a.6, M5a.7) matches a typed query against up to 50k candidates on every key and
shows the best 50 with their matched letters highlighted. B11 gives a key 50 ms to the frame; the
matcher's part is benched on 50k W3 paths. Matching must ignore case, width and accents as
type-to-select and filtering do, with the one fold in `NameSortKey.fold`
([0028](0028-folded-names.md)). The plan asks that "dl" find "Downloads" at the D and the l, and
that "prj1" rank "Project 1" above "pr-junk-1".

## Decision

- **Scoring.** The query's letters must appear in order. Each matched letter earns 10 at the
  start of the text or of a path component (after `/`), 8 at a word start (after a space or
  punctuation, or a capital after a lowercase letter), and 6 right after the previous matched
  letter. A gap costs 3 plus 1 per skipped byte, and a match in a later word than the previous
  one costs 10. The new-word penalty outweighs the word-start bonus, so letters kept in one word
  beat letters spread over word starts: "prj" reads as an abbreviation of "Project", and "dl" as
  one of "Downloads" rather than "Desktop/lib". Entering a word at its start is still far better
  than entering it in the middle. Equal scores rank the shorter text first, then the earlier
  candidate.
- **Best alignment.** A dynamic program over query × candidate bytes finds the best-scoring
  placement, not the first, so "doc" against "old/docs" highlights "docs". Each query byte is
  only tried between the first and last place it can go (a greedy scan from each end), and the
  gap transition keeps two running maxima (any earlier cell, and earlier cells in the same word),
  so a row costs one pass. The scan from the left is also the reject: a candidate missing a
  letter is dropped in one pass with no table.
- **Folded bytes.** A `Candidate` is prepared once: the folded text as one `[UInt16]`, each unit
  a byte plus its position (in a word, word start, component start, separator). An ASCII text
  folds with `NameSortKey.fold` in one call and its offsets line up with the original. A text
  with other characters is folded a character at a time with the same function, keeping each
  folded byte's character offset in an `[Int32]` so the match's ranges point at the original
  characters ("e" highlights the "é" of "Résumé"). Matching is per byte, but a UTF-8
  continuation byte in the query must directly follow its lead byte, so a character matches
  whole, never as bytes taken from different characters.
- **Allocation.** Scoring a candidate allocates nothing on the heap: the window bounds and the
  score table are a `withUnsafeTemporaryAllocation`, on the stack for palette sizes (6 query
  bytes × ~40 path bytes is under 1 KB). `best(_:limit:)` keeps the top `limit` in a sorted array
  with binary insertion, then builds ranges, the only per-result allocation, for those alone.
- **No C.** The bench case scores 50k W3 paths per key of "srcmap", one case per key length,
  against B11. C comes only if Swift misses it, with before and after numbers here.

## Alternatives considered

- **Greedy first match (forward then backward scan, as fzf's v1)** — rejected: it picks the
  first occurrence of a letter, so ranges and scores miss a later word start ("old/docs").
- **Word-start bonus without a new-word penalty (fzf, VS Code)** — rejected: it ranks
  "pr-junk-1" above "Project 1" for "prj1", since every letter of "pr-junk-1" sits at a word
  start, and "Desktop/lib" above "Downloads" for "dl".
- **Match on `Character` or unicode scalars** — rejected: the folded text is canonically
  decomposed, and comparing bytes is what type-to-select does; scalar arrays would cost four
  bytes a scalar per candidate for the same answers.
- **Fold the whole text and map back by re-folding prefixes** — rejected: per-character folding
  gives the map directly, and only non-ASCII texts pay for it.
- **Rescore only the previous key's matches when the query grows** — left to the palette:
  the matcher has no state between keys, and the bench times the full rescore every key.

## Consequences

`FuzzyMatcher` is a value with no state between keys, so the palette can score sources on any
thread. A candidate costs about 2 bytes a folded byte plus its array header, and 4 more bytes a
byte when it isn't ASCII. Camel-case word starts are only seen in ASCII texts. The scores are
plain integers for one query; M5a.6 combines them with frecency and kind order. If B11 misses on
real candidate lists, the next steps are splitting `best` over cores and the incremental rescore
above, before C.
