# 0003. Enumerate directories with getattrlistbulk in Swift

- **Date:** 2026-10-20
- **Status:** accepted

## Context

Opening a folder has to show rows in 50 ms (typical folder) and 100 ms (100k entries), and list
100k entries fully in 500 ms (budgets B2, B5). AGENTS.md allows C for hot paths only with a
benchmark showing the win. Spike S1 measured five methods on generated workloads and on an SMB
share (spike S1).

## Decision

Base lists directories with `getattrlistbulk`, called from Swift, reading name, type, size and
mtime in one call per buffer. Entries are delivered in batches as each buffer is parsed.
Firmlinked entries at a volume root are `stat`ed separately.

## Alternatives considered

- **`FileManager` URLs with resource keys** — rejected: 348 ms for 100k entries, nothing returned
  until the whole folder is read, and 69 MB held.
- **`readdir` + `fstatat`** — rejected: 155 ms for 100k entries, 1.6× slower; first rows arrive
  sooner, which a smaller first `getattrlistbulk` buffer matches.
- **`getattrlistbulk` in C** — rejected: 98 ms vs. 99 ms in Swift, within noise. No benchmark
  justifies a C target.

## Consequences

No C target in Milestone 0. Base owns unsafe-pointer parsing code, which needs tests against
`FileManager` results, including symlinks and firmlinks. On SMB, round trips dominate and the
method barely matters for recursive walks.
