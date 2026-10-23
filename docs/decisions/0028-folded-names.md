# 0028. Fold names once, for the sort key and for matching; read hidden and dataless flags

- **Date:** 2026-10-21
- **Status:** accepted

## Context

Type-to-select (M1.7) and type-to-filter (M1.8) match typed text against names with case,
accents and width ignored: "ré" finds "Resume". `NameSortKey` already folded names that way
before building a key ([0013](0013-name-sort-key.md)), but the folding was spread over the key
build: Foundation folded case and width, and the key builder dropped combining marks as it met
them, putting й and four Arabic letters back together. A second folding for matching would drift
from the first. M1.4 hides hidden files, and M1.11 marks iCloud files that aren't downloaded;
both need flags the lister already requested but didn't keep.

## Decision

- **One fold.** `NameSortKey.fold` lowercases ASCII names byte by byte, and folds other names
  with Foundation's case and width folding, canonical decomposition, and dropping nonspacing and
  enclosing marks and format characters, except where a mark makes a letter the root order keeps
  apart (й). The key is built from the folded name, and its builder traps on a mark, since none
  can reach it. Keys are unchanged: a dump of 600 corpus and generated names' key bytes was
  identical before and after.
- **One pass.** `NameSortKey.foldedNamesAndKeys(for:)` folds each name once and builds its key
  from the fold, in the same parallel chunks as before. `Listing` keeps the folded names
  parallel to `entries` and patches them with the other per-entry arrays.
- **Shared storage.** The fold returns an ASCII name without capitals as it is, so most folded
  names share the entry name's storage and cost 16 bytes in the array.
- **Flags.** `DirectoryEntry` carries `isHidden` (`UF_HIDDEN`) and `isDataless`
  (`SF_DATALESS`), from the bulk call's `ATTR_CMN_FLAGS` or from `st_flags` when the entry is
  stat'ed. A record without flags reads as flags 0. APFS, HFS+, FAT32, exFAT, SMB and devfs
  all return them, and on a file system without flags XNU's `stat` copies the same empty value
  into `st_flags` with no error, so stat'ing the entry would cost a call per entry, 100k round
  trips on an NFS, WebDAV or FSKit folder, for the same answer. `isHidden` doesn't count dot names; the view settings apply that rule. The two flags sit
  after `type` in the struct, in padding before `size`, so the entry stays 48 bytes.

## Alternatives considered

- **Fold with `.diacriticInsensitive` for matching** — rejected: it turns й into и, so matching
  would treat as one letter what the sort order keeps apart, and there would be two folds.
- **Fold to NFC** — rejected: the key needs Hangul as jamo to order 각 before 가나, and one fold
  serves both.
- **Fold names lazily when the user first types** — rejected: the first keystroke on 100k
  entries would pay the whole fold, against B6's 16 ms.
- **Stat an entry whose record lacks flags** — rejected: `stat` reports 0 on the same file
  systems, so it adds a call per entry and changes nothing.

## Consequences

Folded names are canonically decomposed, so a matcher folds the query with the same function
and compares `utf8` views, not characters: `hasPrefix` and `contains` treat a decomposed Hangul
syllable as one character, so 가 wouldn't prefix 각. Matching bytes, typing "가" selects "각",
as typing "a" selects "ab". Dropping nonspacing marks also loosens matching for Indic and Thai
vowel signs and Hebrew points: "कु" folds to "क", so a query matches names that differ only in
those marks. That gives extra matches, never misses.

Only lowercase-ASCII names share storage with the entry. On W2's 100k names, 16,751 folded
names (those with Ü or 日本語) need their own, estimated at 1.1 MB of heap plus 1.6 MB for the
array, about 27 bytes per entry. A 100k folder of capitalized names 16 to 31 bytes long would
take 64 bytes of heap per name on top of the array, about 8 MB, over B9's 5 MB allowance for
folded names, which W2 measures. Non-ASCII names now build one more `String` each before their
key.
