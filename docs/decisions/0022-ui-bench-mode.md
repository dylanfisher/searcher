# 0022. UI bench: 20 direct launches, frames end when the window has drawn

- **Date:** 2026-10-21
- **Status:** accepted

## Context

Decision [0002](0002-performance-measurement.md) times the UI budgets (B1, B2 to the first rows
frame, B6, B8) and counts stalls (B10) inside the app, in a bench mode that `./scripts/bench --ui` launches. The
bench has to run while Dylan uses the machine: his own copy of Searcher, with the same bundle ID,
may be running, and the bench must never take focus. The plan names the pieces (`UIBench`,
`FrameCommitTimer`, `TempRoot`, `AtomicWrite`, the runner reading `.build/bench-ui.json`) but not
how the runner launches the app, where a span ends, or how keys reach a window of an app that
isn't active.

## Decision

- **Launches.** The runner (`Bench --ui <app>`) runs the bundle's executable directly, 20 times,
  each a new process, so every B1 sample is a cold launch with a warm file-system cache. Each
  launch gives one sample of B1, B2.W1, B2.W2 and B8; the first also presses ↓ 500 times (B6).
  Each launch writes its `UIBenchRecord` to `.build/bench-ui.json` through `AtomicWrite`; the
  runner reads it after the process exits, and at the end writes all launches' samples back to
  the same file, in the same shape. The runner passes B10 as `--stall-threshold-ms`. The bundle
  is built at `.build/bench/Searcher.app` (`scripts/bundle -o`), so the dev bundle at
  `.build/Searcher.app`, which may be running and holds its Full Disk Access grant, is left alone.
- **Stopping a launch.** A launch that runs past 120 s gets SIGTERM, which the bench turns into a
  failure that removes its temporary folder and suite; one still running 5 s later gets SIGKILL.
  After any failed launch the runner removes every `TempRoot` with the run's prefix, which it
  passes in `UIBenchOptions`, so a killed launch leaves nothing behind.
- **Shared spelling.** `UIBenchOptions` (the bench arguments) and `UIBenchRecord` (the file) live
  in Base, the only tier both the app and the runner import. `--stall-threshold-ms` moved from
  `StallLogging` to `StallWatchdog` for the same reason, and `scripts/dev` gets the flag and its
  value from `scripts/bench --print-stall-arguments`.
- **Background.** A bench launch uses the `.accessory` activation policy, never calls
  `activate`, orders its window in with `orderFrontRegardless` on the second display when there
  is one, and gives the table first responder without making the window key. Synthetic ↓ events
  go to the window with `sendEvent`, because `NSApplication` routes keys only to the key window
  of the active app. The sort change sets the table's sort descriptors to the next column's
  prototype, the call a header click makes; no mouse event is sent.
- **End of a span.** `FrameCommitTimer` checks after each run loop pass's Core Animation commit
  and stops at the first pass that leaves the window with nothing to lay out or draw. Ending at
  the first commit instead measured ↓ at 0.04 ms: AppKit draws on the display's refresh, so the
  pass that handles the key commits a transaction without the drawing, and the window still
  needed display afterwards. Ended on the drawn frame, ↓ measures 4–9 ms.
- **Start of B1.** The kernel's process start time (`sysctl` `KERN_PROC_PID`), moved onto the
  `NSEvent` timestamp clock. The `launch` signpost can only begin at the top of `main.swift`, so
  it is shorter than the sample by the time before `main` (dyld and the runtime). Running the
  executable directly also leaves out the LaunchServices work that a launch from the Dock or
  Finder pays before the process starts, so B1 here is a lower bound for those.
- **Occlusion.** After the first frame the bench waits up to 2 s for the window to report
  `.visible`, and checks it again before each span and each key press. A window that isn't
  visible prints why on standard error and exits 1, which fails the run. A covered window isn't
  composited, so its times don't reflect what's on screen.
- **Stalls.** The watchdog runs from the top of `main.swift`; the bench stops it before reading
  the stalls, which delivers every stall that has ended. Each `Stall` carries its pass's start
  and end, and each span its start and the moment its frame was timed. When the bench ends, a
  stall is filed under the first span its pass overlaps, else "between spans" (`TimedSpan`).
  Spans run one after another, and a pass can start before its span, since `begin()` runs
  partway through the pass doing the span's work, and end after it, in the pass that commits
  the span's frame. Filing by the span running when the watchdog reported it was
  rejected: the timer's observer ends a span before the watchdog's end-of-pass observer runs,
  so the pass that commits a span's frame, the one most likely to stall, landed between spans.
  The runner prints the count, the longest, and each stall with its span, and never fails on
  them: the plan's budget line for this step says "B10 stall count reported", and B10 in
  [performance.md](../performance.md) is the main thread blocked while a share is slow or gone,
  on W6, which this run doesn't open.
- **Isolation.** `TempRoot` gives each launch a fresh folder, which is the first window's
  folder, and a `UserDefaults` suite stored inside it; the folder is removed before the process
  exits, on failure too. The suite is named by the absolute path `<folder>/preferences`, which
  cfprefsd keeps at `<folder>/preferences.plist`. A plain-named suite lives in
  ~/Library/Preferences, and removing its domain, or clearing its keys and deleting the file,
  still left an empty plist there that cfprefsd wrote back later; tests had left 55 of them.
  CFPreferences treats a domain that starts with "/" as a plist path; that is long-standing but
  undocumented, and it works because Searcher isn't sandboxed. Nothing reads preferences yet; the type that does (Settings) takes the suite from the bench.

## Alternatives considered

- **Launch with `open -n -g`** — rejected: the runner gets neither the app's exit status nor its
  error output, and LaunchServices, given the bundle ID, can bring Dylan's running copy forward.
- **One launch, B1 sampled once** — rejected: every budget is a p95, and one sample has no p95.
- **500 key presses in every launch** — rejected: it adds a few seconds a launch for samples the
  first launch already gives.
- **`CATransaction` commit handlers** — not in the public macOS SDK. A completion block is
  delivered later on the main queue, and nothing ties it to the transaction that holds the
  drawing.
- **The `.prohibited` activation policy** — rejected: such an app may not create windows.
- **Post the keys with `CGEvent`** — rejected: they go to the frontmost app, which is Dylan's.

## Consequences

The bench window appears for about a second per launch above other windows on the second display
and does not take focus. An ad hoc signed rebuild makes the first launch slower while the system checks the new
signature; it is one of 20 samples. The spans run from Swift tasks on the main actor, so objects
autoreleased during a span are released when that task's job ends, in the same pass, as an event
handler's would be. Synthetic events skip the event queue, so time a real key waits there is not
measured. CI does not run `--ui` until M0.16b.
