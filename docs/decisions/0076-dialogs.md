# 0076. Dialogs: one Dialog path, NSAlert sheets on the window they're about

- **Date:** 2026-10-23
- **Status:** accepted

## Context

Each question the app asked built its own window. The confirm, conflict and Go to folder sheets
were hand-made `NSPanel`s with fixed content rects and stacked labels and buttons; the quit
question ([0075](0075-ask-before-quitting.md)) was an `NSAlert`. On 2026-10-23 Dylan sent a
screenshot of the copy confirm: a large white box, the question top left, Cancel and Copy
squeezed under it and a wide empty area below, with a focus ring on Cancel. He asked for one
consistent way to make dialogs that follows the platform's conventions. The sheets also have to
keep what they did: one sheet at a time, queued, never blocking other windows
([0067](0067-operations-panel.md)); Go to folder staying up for a folder that isn't there
([0033](0033-history-and-go-to-folder.md)); and tests that build every dialog without showing it.

## Decision

- **Every dialog goes through `Dialog`, and is an `NSAlert` from `Dialog.alert` wherever its
  buttons fit NSAlert's layout:** message text, informative text, the app icon NSAlert puts in
  by default, and buttons in the order given. The first is the default, which NSAlert places
  rightmost (or on top when it stacks three or more buttons) and gives Return; NSAlert gives
  Esc to the button titled `Dialog.cancel` ("Cancel"). Delete in delete-immediately is marked
  with `hasDestructiveAction`.
- **One exception, the name-conflict sheet, is a `Dialog.rowSheet`.** Finder asks this question
  with four buttons in one row, and NSAlert stacks three or more buttons vertically on macOS 11
  and later, so Finder parity needs a sheet NSAlert can't make. `rowSheet` lays it out like a
  classic alert, from one place: the app icon at 64 pt on the left, the message bold at the
  system size and the information at the small size in a 300 pt column, a checkbox under the
  text when given, 20 pt margins, the buttons in a row along the bottom 12 pt apart with the
  default rightmost, and the window sized to fit. The button it names for Esc takes the keys
  under full keyboard access, as Cancel does in NSAlert.
- **A question about a window's contents is a sheet on that window**, readied by
  `Dialog.sheet`: the alert's buttons send their action to the owner instead of ending the
  alert, and `NSAlert.layout()` sizes the window to its text, accessory view and buttons. The
  owner shows it with `NSWindow.beginSheet` and ends it with `endSheet`, so `OperationPrompter`
  keeps its queue and its `present` and `dismiss` hooks, and Go to folder decides when it
  closes. The quit question is not about one window, so it stays app-modal (`runModal`), built
  by `Dialog.alert` like the rest.
- **The conflict sheet as Finder asks it:** "An item named “X” already exists in this
  location.", then "Do you want to replace it with the one you’re copying?" ("moving?" for a
  move; only copies and moves plan conflicts, and `ConflictRequest.kind` says which), and the
  buttons Keep Both, Stop, Skip, Replace from left to right. Replace is the default (Return),
  as in Finder, and is not styled destructive, as Finder's isn't; Stop takes Esc and cancels
  the operation. "Apply to All" shows only when more conflicts follow. Where it differs from
  Finder: Finder shows Skip only when several items are copied, but the request counts only
  the conflicts still to come, so Skip always shows, which keeps the last of several conflicts
  skippable; and both items' size and date stay as two lines under
  the question, since they fit the layout and Finder offers no other way to compare them.
- **Extra controls in an alert go in the alert.** Go to folder's path field, with the reason
  line under it, is the accessory view; the reason line takes no room while hidden, and
  showing or hiding it lays the alert out again.
- **Keys:** the first responder is what NSAlert picks. With full keyboard access off, buttons
  never take focus, nothing shows a ring, Return presses the default and Esc presses Cancel.
  With it on, NSAlert focuses Cancel, so Space cancels and Return still confirms, as in every
  system alert. Go to folder gives the keys to its field. A file operation's question sheet,
  which appears without a key press, ignores the keys for its first 0.5 s
  ([0067](0067-operations-panel.md), amended 2026-10-26).
- **Errors from the system** (an app that won't open, [0035](0035-system-commands.md)) stay
  with `NSApp.presentError`, which is the system's own alert.
- **The rename field** ([0068](0068-inline-rename.md)) is not a dialog but had the same
  complaint, an effect Finder doesn't have: it is unbezeled with a thin plain border, the text
  background, and no focus ring, so it shows at once with the base name selected, as in Finder,
  instead of animating a ring in.

## Alternatives considered

- **Keep hand-built panels and fix their constraints** — rejected: every sheet would need its own
  spacing, sizing and button rules kept in line with the system by hand, which is how the copy
  sheet drifted. NSAlert follows the system as it changes.
- **`beginSheetModal(for:completionHandler:)`** — rejected: the alert would end on every press,
  and Go to folder must stay up while its folder lists or after it fails. Retargeting the
  buttons keeps one path for both kinds of sheet.
- **The conflict as an NSAlert with stacked buttons** — the first choice, replaced the same
  day: Finder keeps its four buttons in one row with Replace the default, and Finder parity is
  the rule for behavior questions.
- **Make the default button the first responder** — rejected: NSAlert focuses Cancel under full
  keyboard access so Space never confirms by accident; overriding that would make this app's
  alerts behave unlike the system's.

## Consequences

A new question calls `Dialog.alert`, then `Dialog.sheet` if it goes on a window, and gets the
platform's look and keys without layout code; only a question whose buttons must stay in one
row uses `Dialog.rowSheet`, whose layout numbers are copied from the system and won't follow
it if Apple changes the alert. Tests check each dialog's text, buttons, order and key
equivalents without showing it.
