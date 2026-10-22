# 0011. Time stalls with run loop observers, capture stacks from a watchdog thread

- **Date:** 2026-10-20
- **Status:** accepted

## Context

B10 says the main thread is never blocked for more than 50 ms, and decision 0002 says a stall
watchdog measures it in the UI bench and in debug builds. Spike S4 tried a background thread that
pings the main queue every 5 ms and calls it a stall when no reply comes in 50 ms. It detected 14
of 20 caused stalls: a ping only measures from when it was sent, so a stall that starts just
before a ping, or between a reply and the next ping, is seen late or not at all, and its length is
measured short. Capturing the main thread's stack in-process (suspend, walk frame pointers,
resume) cost 0.03 ms median and 0.07 ms max, cheap enough to leave on.

## Decision

`StallWatchdog` times each run loop pass with two observers: one at order `CFIndex.min` starts a
pass on wake or run loop entry, one at `CFIndex.max` ends it before the loop waits, so work in
other observers (Core Animation's commit) counts toward the pass. A pass longer than the threshold
is a stall, reported once with its duration. A watchdog thread waits for the threshold to pass
while a pass is running and captures the thread's stack once with `ThreadStack`, under the same
lock the observers use, so the stack is always from inside the stall. The watchdog takes the run
loop, the thread and the threshold as parameters and holds no threshold of its own.

## Alternatives considered

- **Ping the main queue from a thread (S4)** — rejected: missed 6 of 20 stalls and measured the
  rest short.
- **Observers only, no thread** — rejected: the stalled thread can time its own pass but cannot
  say where it was stuck until the stall is over, when the stack no longer shows it.
- **Capture a stack on a timer, whether or not a pass is late** — rejected: it suspends the main
  thread when nothing is wrong; capturing only past the threshold keeps idle cost at one
  sleeping thread.
- **End the pass when the outermost run loop exits** — rejected: AppKit returns from the run loop
  for each event and calls `sendEvent` outside it, so key and mouse handlers would go untimed.
  The cost is that the watched thread must outlive `stop()`; a capture of an exited thread fails
  a precondition rather than reading another thread.
- **A C target for the frame walk** — rejected: the walk is a dozen Mach calls, and Swift with a
  preallocated buffer meets the S4 cost; no benchmark would show a win.

## Consequences

A pass runs from wake to the next wait, so time spent outside the run loop between two
`CFRunLoopRunInMode` calls (AppKit's `sendEvent` after `nextEvent`) counts, and nested run loops
for menus and modals end the outer pass when they wait. Frames are raw return addresses with
`dladdr` names, mangled for Swift; a function inlined into its caller or reached by a tail call
does not appear. Frame pointers are required, which arm64 macOS always keeps. Debug builds don't optimize, so
the code that runs while the thread is suspended avoids generics, closures, globals and width
conversions: in the debug object its only calls are `thread_get_state` and `vm_read_overwrite`. A stall that ends
before the watchdog thread is scheduled is reported with no frames. Idle CPU cost is timed in
M0.18.
