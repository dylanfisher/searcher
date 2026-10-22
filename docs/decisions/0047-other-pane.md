# 0047. Other pane: the second entry of the layout's focus history

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M3.3 adds the dual-pane keys from `tmp/behavior.md`: Tab focuses the other pane, Cmd-Opt-= opens
the focused pane's folder there, and Cmd-Opt-O opens the selection there. The key table defines
the other pane as the most recently focused other leaf. With one pane, Cmd-Opt-= and Cmd-Opt-O
split right first and keep the focus where it was, and Tab does nothing. `Layout` already keeps
a focus history, most recent first, which focus, split and close update and `TabState` stores
([0042](0042-workspace-model.md)). Like the tiling commands ([0044](0044-tiling-commands.md)),
these need the context's workspace, which the pane's view doesn't pass yet.

## Decision

- **`Layout.otherPane`** is `history[1]`, or `nil` with one pane. Geometry never decides it, so
  a pane that isn't next to the focused one can be the other pane. Focus moves it to the front
  of the history, close drops the closed pane, and move swaps places in the tree without
  touching the history, so the other pane follows the pane, not its position. The history was
  already persisted with the layout; this step adds no stored field.
- **Tab** focuses the other pane through `Tab.focus`, which ends a zoom. A second Tab returns,
  since the two swap places at the front of the history.
- **Cmd-Opt-= and Cmd-Opt-O** end a zoom first, so the other pane shows. With one pane they split
  right, then focus the pane that had the focus again, which makes the new pane the other pane.
  When the split is refused for size they do nothing.
- **Cmd-Opt-=** calls `navigate(to:)` on the other pane with the focused pane's folder, the
  focused column's in column mode. The folder the other pane leaves goes into its history
  ([0033](0033-history-and-go-to-folder.md)), so its Back returns there.
- **Cmd-Opt-O** runs `Pane.openSelection(in:)`, the same code as Open with a pane to send
  folders to: a single selected folder navigates the other pane, a single link goes through the
  other pane's `openLink`, so a link to a folder lists there and a link to a file goes to the
  system, and files open as Cmd-↓ opens them. With one pane it splits right first even when the
  selection is a file, as the key table says.
- **Not in the app yet** (superseded: see [0054](0054-tabs-in-window.md)). `DualPaneCommands`
  is not in `AppCommands.sets`, for the reason 0044 gives. `AppCommandsTests` registers it beside the app's commands and `TilingCommands`, so a
  clash fails now.

## Tab and the keys it meets

No registered command uses Tab. Once M3.5 binds the set:

- **Type-to-select** takes only character keys ([0034](0034-type-to-select.md)), and Tab is a
  named key, so there is no clash. A Tab mid-word runs the command, which ends the typed word
  as any command does.
- **The table** looks up the registry before `super.keyDown` ([0027](0027-key-dispatch.md)), so
  Tab runs the command and `NSTableView` never moves the key view. With one pane Tab does
  nothing and doesn't beep, since a command took it (superseded: see
  [0054](0054-tabs-in-window.md); with one pane Tab moves the key view). Shift-Tab stays unbound and still moves to
  the previous key view.
- **The filter field** gets Tab from its field editor as `insertTab:`, which `FilterBarView`
  doesn't handle, so the field moves the keyboard focus to the next key view and the command
  doesn't run. M3.5 should route `insertTab:` to the registry as the field routes ↑ and ↓, so
  Tab means the other pane wherever the pane has focus.
- **A menu item.** If Focus Other Pane gets a menu item, its key equivalent is plain Tab. M3.5
  has to check that the filter and Go to folder fields still receive Tab, or leave the item out
  of the menus.

## Alternatives considered

- **The nearest pane, or the one to the right** — rejected: the key table defines the other
  pane by focus, and with three or more panes geometry has no single answer.
- **A history kept in `Tab` or `DualPaneCommands`** — rejected: `Layout` already has one, which
  close and focus keep in step and `TabState` stores. A second copy could disagree with it.
- **Cmd-Opt-O opening a file in the other pane's folder, or doing nothing on a file** —
  rejected: the step asks for a file to open as Cmd-↓ does.
- **A copy of `openSelection`'s rules in `DualPaneCommands`** — rejected: Open's handling of a
  provisional selection, links and several selected entries would then live in two places.
- **Leave zoom alone** — rejected: the other pane would change while hidden, so the key would
  look like it did nothing.

## Consequences

M3.5 adds `DualPaneCommands` to `AppCommands.sets` with `TilingCommands`, builds each context
with the workspace and `tabBounds`, routes the filter field's Tab, and decides on the menu item.
The window has to show a pane added by the one-pane split, as it does for Split Right, and call
`didGainFocus` and `didLoseFocus` when Tab moves the focus. With the table taking Tab, keyboard
users reach the path bar and filter field by pointer or by their own keys, not by Tab.

Ctrl-Tab beeps in the table today: it carries a modifier and no command takes it, so the table
beeps instead of passing it to `super` ([0027](0027-key-dispatch.md)). Suggestions for M3.5:

- Give `focusOtherPane` an `isEnabled` of `otherPane != nil`, and pass Tab to `super` when it is
  disabled, so with one pane Tab moves the key view as it does now.
- Let Ctrl-Tab and Ctrl-Shift-Tab reach `super`, so they move the key view, unless M3.5 binds
  them to next and previous tab as the key table asks.
- Route the filter field's `insertTab:` to the registry, as above.
- Keep Shift-Tab unbound.
