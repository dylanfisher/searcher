# 0066. File commands: queue in the context, confirm through its prompts, select by version

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M4.5 makes trash, new folder, duplicate, rename, and copy and move to the other pane into
registered commands on the keys in `tmp/behavior.md`, run through the operation queue
([0065](0065-operation-queue.md)). The queue takes its `Prompts` when it is made, and nothing
answers them until the operations panel and its sheets (M4.6), so the app has no queue yet. The
inline rename field is M4.7. New folder and duplicate pick their names when they run, so a
command learns them only from the operation's record, and the pane lists them only once its
monitor reports them.

## Decision

- **Keys**, all from the key table, none taken: Cmd-Delete Move to Trash, Cmd-Shift-N New
  Folder, Cmd-D Duplicate, Return Rename, Cmd-Shift-C Copy to Other Pane, Cmd-Shift-M Move to
  Other Pane.
- **The queue comes in the context.** `CommandContext.fileOperations` is optional: with no
  queue every file command is off, so a window whose questions nothing can answer shows them
  disabled rather than trapping on a key. `editName`, the view's way to start the rename field,
  is optional for the same reason, and Rename is off without it.
- **Each command checks again when it runs.** The table runs a key's command whether or not it
  is enabled ([0060](0060-menu-items-for-every-command.md)), so each one does nothing when its
  `isEnabled` would say no.
- **What is on.** Every file command needs a queue. Move to Trash, Duplicate and the two
  other-pane commands need a selection; Rename needs exactly one selected entry; the other-pane
  commands also need a second pane (`Layout.otherPane`) and, unlike Cmd-Opt-O, don't split to
  make one. New Folder needs only the queue.
- **The other pane's folder** is that pane's `location`, its focused column's folder in column
  mode, read when the key is pressed.
- **Confirm through the queue's prompts.** Copy and Move to Other Pane ask
  `ConfirmRequest.otherPane` with the operation through the queue's own `Prompts.confirm`, so
  one answerer serves the queue's questions and the commands', and queue it only on yes. The
  question is asked before anything is queued, so nothing is planned or refused until then.
- **Selecting what was made.** New Folder, Duplicate and `FileCommands.rename` read the pane's
  selection version when they start and, once the operation finishes, ask the pane to select
  the names its record created or moved to. The pane selects them, the cursor on the last, as
  soon as its rows list them all: at once, or when the load or patch that brings the last one
  lands. If the selection version has moved, by the user selecting something else or the pane
  leaving the folder, before or after the operation ends, the names are dropped. They are also
  dropped when the user selects anything, even the rows already selected, when the filter
  changes, and when hidden entries show or hide: a name the filter or the setting hides would
  otherwise be selected whenever it showed later.
- **Names compare exactly.** A name the volume lists in another Unicode normalization than the
  record's, which can happen on HFS+ and exFAT, is never found, so it isn't selected; nothing
  else follows from it.
- **Rename** is two parts: the command starts the view's field, and the field commits with
  `FileCommands.rename(_:to:in:queue:)`, which returns the operation's last state so the field
  can show why a rename failed.
- **Menu items** go in File, where Finder has them: New Folder after New Window; Rename (no key
  equivalent, since Return is a text field's key), Duplicate and the two other-pane items in a
  group; Move to Trash in its own group. Cmd-Delete has no receiver while a text field has the
  keys, so its item is off there and the field keeps the key.

## Alternatives considered

- **A context that traps without a queue**, as the other view hooks do — rejected: the app has
  no queue until M4.6, and Cmd-Delete in the list would crash it.
- **Make the queue in the app now with prompts that always answer no** — rejected: every
  replace and other-pane copy would silently do nothing.
- **A separate confirm hook in the context** — rejected: a second way to ask the user what the
  queue's prompts already ask, which Interface would have to wire twice.
- **Only drop the pending names when the selection changes** — rejected: the names are known
  only once the operation ends, so a click made before that would still be overridden.
  Comparing the selection version from when the command ran catches both orders.
- **Select the moved items in the other pane** — not now: the key table doesn't ask for it.

## Consequences

Until a window passes a queue, the file commands are off in the app. Each key press queues one
operation, however many entries are selected, so it starts one plan thread; a trash of 1,000
items is one plan. Holding Cmd-D repeats the key and queues one duplicate per repeat, each with
its own plan thread and each in its volume's lane; no cap on plan threads is needed for these
commands. Two presses of Cmd-Shift-C before the first is answered ask two questions at once,
which the sheet that answers them has to queue or refuse. The new names are selected through
`Pane`, so the view follows them as it follows any selection change.
