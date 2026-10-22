# Performance

Budgets every change is measured against, the workloads they run on, and how they're checked.
`Sources/Bench/Budget.swift` holds the same numbers for the harness, and a test fails if the two
differ. A budget with one number per workload has one ID per workload there, such as `B2.W1`.

## Reference workloads

| ID | Workload | Where | Source | In CI |
|---|---|---|---|---|
| W1 | Typical folder, ~300 entries (Desktop/Downloads shape) | local | generated | yes |
| W2 | Flat folder, 100k entries: files plus 1% dot files and 1% empty folders | local | generated | yes |
| W3 | Deep tree, node_modules shape (~60k files, ~8k dirs) | local | generated | yes |
| W4 | Music library, 3.1k dirs (artist/album/tracks) | SMB, wired 1 GbE | Dylan's NAS | manual |
| W5 | `/` with hidden files shown | local | real | yes |
| W6 | W4 with the share slowed or pulled mid-listing | SMB | Dylan's NAS | manual |
| W7 | External USB disk (exFAT and APFS) | external | real | manual |
| W8 | Copy load, 10 GB: 4 × 2 GB files plus 20k files of ~100 KB | local, to an attached disk image | generated | 2 GB variant |

Generated workloads are built by a script from a fixed seed in a temp folder, so runs repeat.
SMB and external numbers are checked by hand at milestones; CI can't reach the NAS.

## Budgets per interaction

Warm cache unless noted. The budget is the p95 of the runs.

- **B1 cold:** a new app process, not running before; the file-system cache is left warm.
- **B3 cold:** each run opens a different never-opened folder
  (`./scripts/bench --cold-children <dir>`, or to the first rows frame with
  `--ui --scenario cold --path <dir>`), or the share is remounted between runs. The report says
  which.
- **B9:** the process's `phys_footprint` after the listing is loaded, minus before.

| ID | Interaction | Workload | Budget |
|---|---|---|---|
| B1 | Cold launch → restored windows visible | — | 500 ms |
| B2 | Open folder → first rows visible | W1 / W2 | 50 ms / 100 ms |
| B3 | Open SMB folder → first rows (cold, album of ~20 entries) | W4 | 150 ms |
| B4 | Revisit SMB folder → cached rows visible | W4 | 16 ms |
| B5 | Fully listed and sorted | W2 / W3 (recursive, for folder sizes) | 500 ms / 2 s |
| B6 | Key → selection moved | W2 | 16 ms |
| B7 | Type-to-filter keystroke → list updated | W2 | 50 ms |
| B8 | Sort column change → redrawn | W2 | 150 ms |
| B9 | Memory per 100k entries | W2 | 60 MB |
| B10 | Main thread blocked while a share is slow or gone | W6 | never > 50 ms |
| B11 | Palette keystroke → list updated, 50k candidates | W3 paths | 50 ms |

## Regression rule

| Gate | Runs bench | Fails on |
|---|---|---|
| `./scripts/check` | no | — |
| CI | yes | harness p95 over budget; UI bench p95 over budget once its p95s stay within 10% across three consecutive runs (reported until then); a harness case >10% slower than the last run on the same branch, else `main`, is reported, not failed |
| Milestone | manual W4, W6, W7 | any budget miss |

## Measurement

| Budgets | How | Command |
|---|---|---|
| B2–B5, B7–B9, B11 (model part) | In-house harness, release build, W1–W3 and W5, median and p95 of 20 runs | `./scripts/bench` → `.build/bench.json` |
| B1, B6, B10; B2 (open → first rows frame); B7, B8, B11 (key → frame) | In-app timing in a bench mode: launch → first frame committed; open → frame with first rows committed; `NSEvent` timestamp → frame committed over 500 synthetic ↓ presses, 200 of each other row command, 100 Cmd-A presses, 100 patches and 20 reloads landing with every row selected, 100 patches adding a row under Select All, 100 clicks selecting half the rows, 100 patches landing after a Shift-↓ sent while they run, 20 reloads with Cmd-A pressed on the first batch, and the keys of two 12-character type-to-select queries, each its own B6 case; a sort column change, Cmd-Shift-. on and off, Folders First on and off, and two sort keys, each its own B8 case; the five keys of a filter query and the Esc that clears it, one B7 case; in column view on W2 sorted with Folders First, 500 ↓ presses through folder rows, each opening its folder's column, and 100 each of → and ←, three more B6 cases; 500 ↓ presses in the focused pane of a two-pane split and of a 4-pane grid on W2, two more B6 cases, failing if an unfocused pane needs drawing during them; ten panes opening W2 at once, the focused pane's load asked last, to the frame with the focused pane's first rows, once per launch, a B2.W2 case, with the stalls of the ten-pane load counted; a main run loop observer times stalls > 50 ms and the watchdog thread captures their stacks | `./scripts/bench --ui` → `.build/bench-ui.json` |
| B3 cold, B4, B6 and B10 on a share | The UI bench mode, one launch per scenario, on a `--path` folder that has no default: `cold` opens 20 never-opened subfolders once each to their first rows frame (B3, the same subfolders as `--cold-children`; once per mount; run before revisit, since a second run on the same mount passes with warm numbers); `revisit` opens them, then opens each again to the frame with its cached rows (B4); `column-walk` walks the folder in column view with ↓, → and ←, each key to its frame (B6), and fails on any stall after the launch warm-up (B10) | `./scripts/bench --ui --scenario <name> --path <dir>` → `.build/bench-ui-<name>.json`; `--help` lists the scenarios |
| W4, W6, W7 | Same bench modes pointed at the NAS and external disk, run by hand | at milestones |

The stall watchdog also runs in debug builds, so hangs show up in daily use. OSSignposter marks
sit on the same intervals, so Instruments shows them if Xcode is installed later. Rationale:
[0002-performance-measurement](decisions/0002-performance-measurement.md); how the UI bench
launches the app and where its spans end: [0022-ui-bench-mode](decisions/0022-ui-bench-mode.md).
