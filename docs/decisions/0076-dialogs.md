# 0076. Dialogs: one NSAlert path, sheets on the window they're about

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

- **Every dialog is an `NSAlert`, built by `Dialog.alert`:** message text, informative text,
  the app icon NSAlert puts in by default, and buttons in the order given. The first is the
  default, which NSAlert places rightmost (or on top when it stacks three or more buttons) and
  gives Return; `Dialog.cancel` ("Cancel") gets Esc. A button that loses data is marked with
  `hasDestructiveAction`: Delete in delete-immediately, Replace in the conflict sheet.
- **A question about a window's contents is a sheet on that window**, readied by
  `Dialog.sheet`: the alert's buttons send their action to the owner instead of ending the
  alert, and `NSAlert.layout()` sizes the window to its text, accessory view and buttons. The
  owner shows it with `NSWindow.beginSheet` and ends it with `endSheet`, so `OperationPrompter`
  keeps its queue and its `present` and `dismiss` hooks, and Go to folder decides when it
  closes. The quit question is not about one window, so it stays app-modal (`runModal`), built
  by `Dialog.alert` like the rest.
- **Extra controls go in the alert, not in a new layout.** The conflict sheet's "Do the same for
  N more conflicts" is the alert's suppression button with that title, shown only when more
  follow; both items' size and date are two lines of informative text. Go to folder's path
  field, with the reason line under it, is the accessory view; the reason line takes no room
  while hidden, and showing or hiding it lays the alert out again.
- **Keys:** the first responder is what NSAlert picks. With full keyboard access off, buttons
  never take focus, nothing shows a ring, Return presses the default and Esc presses Cancel.
  With it on, NSAlert focuses Cancel, so Space cancels and Return still confirms, as in every
  system alert. Go to folder gives the keys to its field.
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
- **A custom sheet for the conflict, with the buttons in one row as Finder lays them out** —
  rejected: NSAlert stacks three or more buttons on macOS 11 and later, which is the system's
  layout for this many choices, and both items' details fit in informative text.
- **Make the default button the first responder** — rejected: NSAlert focuses Cancel under full
  keyboard access so Space never confirms by accident; overriding that would make this app's
  alerts behave unlike the system's.

## Consequences

A new question calls `Dialog.alert`, then `Dialog.sheet` if it goes on a window, and gets the
platform's look and keys without layout code. Tests check an alert's text, buttons and key
equivalents without showing it. NSAlert's narrow width wraps long lines, such as the conflict's
item details; a wider alert would need an accessory view to set its width.
