# Searcher

A fast, keyboard-driven file manager for macOS with multi-window, tiling, and dual-pane layouts.

Requires macOS 14 or later. Distributed by direct download, not the Mac App Store.

## Develop

Needs Swift 6.2 or later (Command Line Tools or Xcode).

| Task | Command |
|---|---|
| Bootstrap, install the commit hook | `./scripts/setup` |
| Run the app | `./scripts/dev` |
| Run tests | `./scripts/test` |
| Fix formatting | `./scripts/format` |
| Full gate — format, build, tier rules, tests | `./scripts/check` |

CI runs `./scripts/check` on every push.

## Layout

| Path | Purpose |
|---|---|
| `Package.swift` | Targets and their dependencies — the tier map. |
| `Sources/` | One directory per target: Base, Browser, Interface, Searcher. See [docs/map.md](docs/map.md). |
| `Tests/` | Mirrors `Sources/`. |
| `AGENTS.md` | Instructions for AI coding agents. |
| `docs/principles.md` | Rationale behind the rules in AGENTS.md. |
| `docs/writing.md` | Comment voice and commit format. |
| `docs/decisions/` | Why things are the way they are. |

## License

MIT — see [LICENSE](LICENSE).
