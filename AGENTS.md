# AGENTS.md

Instructions for AI coding agents working in this repo. Humans: see [README.md](README.md).

**Keep this file under ~50 lines.** Anything longer lives in `docs/` and is linked from here.

## Stack

- **Language:** Swift 6 (language mode 6, tools 6.2), macOS 14+; C for profiled hot paths
- **Package manager:** SwiftPM only — no `.xcodeproj`
- **Framework:** AppKit; SwiftUI only for peripheral UI (settings, popovers)
- **Test framework:** Swift Testing (`import Testing`, `@Test`)
- **Layout:** `Sources/<Target>/`, tests in `Tests/<Target>Tests/` — tiers and search recipes: [docs/map.md](docs/map.md)

## Commands

| Task | Command |
|---|---|
| Install / bootstrap | `./scripts/setup` |
| Run locally | `./scripts/dev` |
| Run tests | `./scripts/test` |
| Run the tests for what you changed | `./scripts/test --changed` |
| Fix formatting | `./scripts/format` |
| **Full gate** | `./scripts/check` |

`./scripts/check` is the gate — see Definition of done. Iterate with `./scripts/test --changed`; run `check` once, at the end.

## Principles

Non-negotiable, regardless of stack. Rationale: [docs/principles.md](docs/principles.md).

1. **Single source of truth.** Every fact — a constant, type, config value, copy string — is defined once and imported. Never re-declare, never re-derive. **Search before you create** — [docs/map.md](docs/map.md) has the recipes.
2. **Match the surrounding code.** Consistency beats personal preference. Read a neighboring file before writing a new one; map.md says which one is the neighbor.
3. **DRY on the third occurrence, not the second.** Premature abstraction costs more than duplication.
4. **Smallest change that solves the problem.** No drive-by refactors, renames, or reformatting outside the task.
5. **Fail loudly.** No empty catches, no silent fallbacks, no defaults that mask a missing value.
6. **Delete, don't comment out.** Git remembers.
7. **No new dependencies without asking first.** Say what it's for and what it replaces.
8. **Style is the formatter's job.** If a tool enforces it, it does not belong in this file or in review.

## Boundaries

- `Package.swift` is the tier map. Never add a dependency that points up a tier; a new target updates `docs/map.md` in the same commit.
- No file-system I/O on the main thread. Listings, stats and watches run off the main actor.
- New C code needs a benchmark showing the win over Swift, recorded in `docs/decisions/`.
- **Pre-release:** breaking changes are fine. Stored data has one shape — no version fields, migrations, or compatibility shims; data that doesn't match is discarded. Delete this line at the first production release.

## Definition of done

- `./scripts/check` passes clean, and no budget in [docs/performance.md](docs/performance.md) is missed.
- New behavior has a test that fails without the change.
- No new dependencies, no new files outside the agreed layout, no TODOs left behind.
- If a decision was non-obvious, record it in `docs/decisions/`.
- Comments, docs, and commit messages follow [docs/writing.md](docs/writing.md).
