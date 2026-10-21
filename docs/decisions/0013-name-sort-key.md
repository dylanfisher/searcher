# NNNN. Build the name sort key from root collation order, not from folded UTF-8

- **Date:** 2026-10-20
- **Status:** accepted

## Context

`0004-listing-view.md` sorts by name with a precomputed key whose byte order follows
`localizedStandardCompare`. The spike's key folded case, accents and width, zero-padded digit runs
to 20 digits, and compared the result as UTF-8. It matched Finder on W2, whose names are mostly
ASCII letters and digits. On the M0.3 corpus (accented Latin, Greek, Cyrillic, Hebrew, Arabic,
CJK, emoji, punctuation, long digit runs) it ordered 4,249 pairs differently from
`localizedStandardCompare`. UTF-8 order puts punctuation, digits and letters in ASCII order, puts
emoji after every script, and orders scripts by code point; the root collation order behind
`localizedStandardCompare` puts whitespace, punctuation, symbols and digits before all letters,
and letters by script. Fixed 20-digit padding also misorders runs of 21 digits or more.

## Decision

`NameSortKey` writes one class byte per character in root order (whitespace, punctuation and
symbols, digit runs, other numbers, then letters by script), followed by a rank or the scalar's
UTF-8. Latin, Cyrillic and Arabic letters, and common punctuation and symbols, take ranks from
ordered tables measured against `localizedStandardCompare` on macOS 26.6. A digit run is its
digit count without leading zeros, then its digits. The tests check every pair of corpus names,
and every pair of characters from the rank and spelling tables, against
`localizedStandardCompare` in the `en_US` locale. They fail on any pair not on the kept-mismatch
list, and on any kept pair that stops mismatching.

## Alternatives considered

- **The spike's folded UTF-8 key** — rejected: 4,249 mismatched pairs on the corpus.
- **ICU sort keys (`ucol_getSortKey`)** — rejected: the macOS SDK ships no `ucol.h`, so calling
  libicucore's collator means declaring private API by hand.
- **Zero-padding digit runs to a fixed width** — rejected: any width short of 255 misorders
  longer runs, and 255 makes every key with a number hundreds of bytes long.
- **Folding with `.diacriticInsensitive`** — rejected: it turns й into и and أ into ا, which the
  root order keeps as separate letters. The key decomposes canonically and drops combining marks
  itself, putting those letters back together.

## Consequences

Name sort costs byte comparisons only, and the key build stays near the spike's 8 ms for 100k
names in 8 chunks. The key follows the root order only: locales with their own order (Swedish å,
ä, ö after z) differ, and so does any script without a table where it isn't in code point order.
Han sorts by code point rather than radical and stroke. A macOS update can change
`localizedStandardCompare`; the corpus test then fails and names the pairs.
