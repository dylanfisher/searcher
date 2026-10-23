# 0075. Ask before quitting while file operations run

- **Date:** 2026-10-23
- **Status:** accepted

## Context

Quitting cancels every file operation and cleans up after it
([0065](0065-operation-queue.md)), with no question. Dylan asked on 2026-10-23 to match Finder,
which asks before it stops a copy. The question must be testable without showing a window, and
`applicationShouldTerminate` must answer AppKit at once or say it will answer later.

## Decision

- **When it asks:** while the queue has an unfinished operation, paused and
  waiting-for-an-answer ones included, or a question sheet shows or waits, such as the
  other-pane confirm asked before anything is queued. With none of these it quits as before.
  The count is `FileOperationQueue.unfinishedCount`, kept under the lock that takes in
  submissions: up by one as an operation is submitted, down by one as it finishes. It is read
  without waiting for the actor, so a copy queued a moment before Cmd-Q counts though no
  snapshot has shown it yet.
- **What it asks:** "Quit while a file operation is running?" ("while 3 file operations are
  running?"), saying that quitting stops them and removes what they were partway through
  writing; "Quit while a file operation waits for an answer?" when only a question waits.
  Quit is the first button, so Return quits, and Cancel the second, which Esc presses, as in
  Terminal's question about running processes.
- **Where it lives:** `WorkspaceWindows.quitAlert` builds the `NSAlert` and
  `shouldQuit(asking:)` decides, taking the call that shows it. Tests pass a closure and check
  the alert's text without showing it; the app delegate passes `runModal`. Quit then runs the
  existing cancel-and-clean path; Cancel answers `.terminateCancel` and leaves everything
  running.

## Alternatives considered

- **Count the operations in the queue's latest snapshots** — rejected: they come at most every
  100 ms (`snapshotInterval`), so a copy queued in the last 100 ms before the quit would be
  cancelled without asking.
- **Ask the actor for its unfinished entries** — rejected: the answer would come after
  `applicationShouldTerminate` returned, and the actor takes in submissions only when it runs.
- **A sheet on the front window** — rejected: with no window open there is nowhere to put it,
  and a sheet already showing a question would have to close first.
- **Cancel as the default button** — rejected: Return confirming the quit the user asked for
  matches Terminal's question.

## Consequences

A quit at logout or restart with operations running waits for the answer, which stops the
logout until the user answers, as Finder and Terminal do. Promised files still on their way
into a drop folder don't count: they aren't queued operations, and quitting removes their
folders as before ([0071](0071-drag-and-drop.md)).
