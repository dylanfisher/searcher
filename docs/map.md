# Code map

Where things live, and how to find one before you build a second. Read this before creating any
new file.

This file describes **shape, not contents** — conventions and search commands, never an inventory.
An inventory would be a second copy of facts the code already holds, it would rot within a week,
and it would have no error message when it diverged. If you catch yourself listing what exists
here, stop: the grep is the list.

## Find before you create

The single rule that matters. AGENTS.md principles 1–3 (single source of truth, match the
surrounding code, DRY on the third occurrence) all depend on it — none of them can be followed
against a codebase you haven't searched.

| Before adding… | Run |
|---|---|
| any named thing | `rg -i '<name>' --type swift --type c` |
| a building block | `ls Sources/Base/ Sources/C*/` |
| a model type or command | `ls Sources/Browser/` |
| a view or controller | `ls Sources/Interface/` |
| a free function | `rg '^\s*(public )?func ' Sources/Base/` |
| a preference | `rg '<key>' Sources/Browser/Settings.swift` — preferences are read in one type only |
| a type | `rg '(struct\|class\|enum\|protocol\|actor) <Name>\b'` |

If a search turns up something close but not identical, that's the second occurrence. Use it or
duplicate it — do not abstract yet (principle 3).

## Tiers

The default vocabulary below is a recommendation, not a mandate. **Rename these to whatever fits
the project** — `modules`, `services`, `packages`, `internal` are all fine. What must not change is
the dependency direction.

| Tier | Path | What belongs here | May import from |
|---|---|---|---|
| **c** | `Sources/C*` | Plain C for measured hot paths only (bulk directory reads, matching). Added when a profile justifies it, never speculatively. | system headers |
| **base** | `Sources/Base` | Domain-free building blocks: paths, file-system enumeration, matching. Foundation only, no AppKit. Portable as-is. | c |
| **browser** | `Sources/Browser` | The file-manager model: listings, selection, the pane/tiling layout tree, commands, `Settings`. No AppKit — testable without a window. | base, c |
| **interface** | `Sources/Interface` | AppKit windows, split panes, table views, keybindings. | browser, base |
| **app** | `Sources/Searcher` | The executable: app delegate, menus, wiring. Kept thin. | everything |
| **tools** | `Sources/Bench` | The release-mode benchmark runner, its cases, and `Budget`, the only copy of the budget numbers in code. Nothing imports it. | browser, base |

**Dependency direction is one-way: app → interface → browser → base → c.** Never upward. Tools
sit beside the app: they import browser and base, and nothing imports them.

Each tier is a SwiftPM target, so `Package.swift` is the dependency map. The build rejects an
import of any target that isn't a declared dependency, and because the tiers form a chain, an
upward dependency is a cycle, which SwiftPM refuses. `scripts/arch` covers the one rule the
compiler can't see: no AppKit, SwiftUI or Cocoa import in Base or Browser.

## Naming

- One thing per file; the filename is the thing's name.
- File names singular, after the type they hold: `Location.swift`, not `Locations.swift`.
- Tests mirror the tree: `Sources/Browser/Location.swift` → `Tests/BrowserTests/LocationTests.swift`.
- C targets are named `C<Purpose>` (`CDirScan`), expose one header in `include/`, and get a Swift
  wrapper in Base — nothing above Base calls C directly.
- AppKit subclasses keep their AppKit suffix: `…WindowController`, `…ViewController`, `…View`.

## Promotion

Things move up a tier deliberately, never by accident:

- **Third occurrence** → extract to the lowest tier that all three callers can reach (principle 3).
- **Browser type loses its project knowledge** → it belongs in Base; move it down.
- **Base type grows a domain type or a `Settings` read** → it belongs in Browser; move it up.

A promotion is its own commit, separate from whatever work revealed it (principle 4).

<!-- paths: Sources/Base Sources/Browser Sources/Interface Sources/Searcher Sources/Bench -->
<!-- ↑ scripts/check verifies every path above exists. Keep it in sync with the Tiers table;
     a rename that misses this line fails the gate, which is the point. -->
