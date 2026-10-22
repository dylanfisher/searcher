# 0024. Warm each script's fonts once, off the main thread, after the first frame

- **Date:** 2026-10-21
- **Status:** accepted

## Context

B10 says the main thread is never blocked for more than 50 ms. At M0's end the stall watchdog
(decision [0011](0011-stall-watchdog.md)) logged two kinds of stall that a process pays once:
69 ms preparing the first table row view in Dylan's dev session (`NSTableRowData
_preparedRowViewForRow` → `addSubview` → the text field cell's semantic-context refresh), and
67 ms in the UI bench's W2 sort change, inside CoreText loading a fallback font and its glyph
advances for the fixture's Japanese names. Before this change, on an idle machine, the sort
change stalled in the first of the 20 launches on every run, the launch that presses ↓ 500
times first: 57–71 ms against 33–42 ms in the other 19. Stacks caught it in CoreText twice
(`XTCopyFontWithName`, a font lookup through fontd, and `TFont::FinishConstruction` →
`CGFontCreateWithPathAndName`, a fallback font read from disk). W2's names are the first
non-Latin text the bench draws; its words include "Ünïcødé" and "日本語".

The warm-up must not delay the first frame (B1) or the first rows (B2), and the bench must time
what a normal launch does.

## Decision

`LaunchWarmup.shared.start(after: window)` is called once the first window is ordered in, by the
app delegate and by the UI bench at the same point. It waits, through `FrameCommitTimer`, for
the pass that commits the window's first drawn frame. Then, off the main thread, it draws one
sample string per script into a bitmap with `CTLineDraw`, in the system font at the size
`NSTextField` labels use, so CoreText picks and reads each fallback font, shapes the text and
rasterizes its glyphs. The scripts are the
fixtures' (Latin with diacritics, Japanese) and those a music library's names commonly use
(Chinese, Korean, Cyrillic, Greek, Arabic, Hebrew, Thai, Devanagari). CoreText's font and
cascade caches are process-wide, so the main thread's later drawing finds them loaded.

A second `start` does nothing. The UI bench waits for `finished()` before its first span after
launch: a person's first click comes later than the warm-up ends. In the release build it
takes 4–6 ms, logged once per launch in the `warmup` category. Because the bench waits,
the overlap between the warm-up and a normal launch's first rows, which land around the same
time, is not timed.

The first row view is not warmed. In five direct launches of a release build (window ordered
in without activating the app), home's first cell was made 14–21 ms after the window was
ordered in, before the first frame committed 22–27 ms later, and about 30 ms before a warm-up
after that frame could make one. The first rows of a normal launch are home's, so a row-view
warm-up after the first frame comes too late to take their cost, and one before it would only
move that cost to another place inside B1. The text field cell's semantic-context refresh
seen in the 69 ms stall does run for a table in no window (traced with lldb: 4 calls of
`-[NSTextFieldCell _controlViewDidChangeEffectiveSemanticContext:]` per row in no window, 7 in
a window that is never shown), so an off-screen warm-up would have reached it; it just can't
run early enough. In that session home was listed first, so the 69 ms stall was not
the process's first row view either.

## Alternatives considered

- **Warm before the first frame** — rejected: it adds its time to B1.
- **Draw the samples on the main thread** — rejected: that is the 67 ms the step removes, moved
  to launch.
- **Also prepare row views off screen, after the samples** — tried and removed: as above, the
  first rows of a normal launch are built before it runs, so it warmed nothing they use.
- **Let the bench open W1 while the warm-up runs** — rejected: no person opens a folder within
  the warm-up's few milliseconds of the first frame, and overlapping would time CoreText's locks
  shared with the warm-up's thread rather than the open.
- **Run the warm-up only in the bench** — rejected: the bench would look better than a launch.

## Consequences

Measured with `./scripts/bench --ui` on Dylan's machine, `--check-idle` saying idle before and
after each run. The baseline is 259fc99. Five runs of an earlier version that also prepared row
views off screen, alternated with the baseline, gave the same results as the two runs of this
version below:

| | Baseline, 6 quiet runs | Change, 2 quiet runs |
|---|---|---|
| B1 p95 | 76.8–94.9 ms, median 80.5 | 88.2 and 86.6 ms |
| Stalls in the sort change | 1 per run, launch 1, 57–71 ms | 1 per run, launch 1, 66.7 and 64.7 ms |
| Other stalls | one of 51 ms in one run, in launch | one of 50.4 ms in one run, in launch |
| CoreText frames in stall stacks | 2 runs of 6 | none |
| Sort change, launches 2–20 | median 33.4–33.8 ms | median 33.2–33.4 ms |

The warm-up takes CoreText's font loading out of later frames, but that was not what made the
launch-1 sort change long. Timed inside the pass, with and without the warm-up, it is the pane
sorting 100k entries on the main thread (17 ms, against 8 ms in later launches), the reload
(5–6 ms), scrolling to the selected row, which moved far down the list (15–18 ms), and
drawing the new rows (about 20 ms). None of that is paid once per process, so this record
doesn't close B10 for the sort change; it needs the sort off the main thread or the scroll in
a later pass. A busier machine (a browser or a VM using one core) adds 5–14 stalls of 50–87 ms
to the launch span, before and after this change alike, in the first frame's drawing and
window-server calls; the warm-up runs after that frame, so it can't touch them.

The samples cover the scripts named above; a name in another script still pays its font's first
load in the frame that first shows it. Each fallback font read adds to the process's memory.
