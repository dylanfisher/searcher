# 0006. One listing service, at most four loads at once, first batch then full listing

- **Date:** 2026-10-20
- **Status:** accepted

## Context

A restored workspace can open many panes at once, some on 100k-entry folders or on a share.
First rows must appear in 100 ms (B2), the full listing in 500 ms (B5), and the main thread must
never stall (B6, B10). Spike S4 compared an actor per pane, a single serial service and bounded
concurrency, with and without a small first batch (spike S4).

## Decision

A single listing service owns a work queue and runs at most four loads at once at userInitiated
QoS. The focused pane's load jumps the queue. Each load delivers a sorted first batch of 200
entries, then the full sorted listing; sort keys are built in parallel chunks. Batches reach the
main thread as one array swap and `reloadData`. Folder-size walks run on a separate, cancelable
queue at utility QoS, four at once.

## Alternatives considered

- **Actor per pane, unbounded** — rejected: fastest first rows, but dropped frames (up to 54 ms)
  with ten 100k-entry folders loading together.
- **One serial service** — rejected: no dropped frames, but the last of ten panes waited 1.4 s
  for first rows.
- **No first batch** — rejected: 163 ms to first rows on a 100k folder, over B2.
- **Background QoS for listing** — rejected: about 2× slower.

## Consequences

Rows reorder once when the full listing replaces the first batch. Panes beyond the fourth wait
for a slot, which only shows when several huge folders load at once. The queue gives one place
to cancel loads when a pane navigates away.
