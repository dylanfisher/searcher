# 0089. Pane and window keys work while the sidebar has the keys

- **Date:** 2026-10-24
- **Status:** accepted
- **2026-10-26:** No pane shows the focus ring while the sidebar has the keys, and the commands
  that focus another pane move the keys out of the sidebar into it; see "The focus ring" and
  "Where the keys stay".

## Context

Dylan, 2026-10-24: "window pane and all other shortcuts should work even when sidebar is focused,
and act on either the focused pane or the first pane in the window if no pane is focused".

With the keys in the workspace sidebar ([0086](0086-workspace-sidebar.md)) only the window and
tab commands worked. A command's chord reaches the pane in one of two ways. A chord with a menu
item sends `runMenuCommand:` up the responder chain; only a pane's table implements it, and the
window controller, at the end of the chain, took the item only for the window and tab commands
([0054](0054-tabs-in-window.md)), to leave a text field its editing keys. Every other chord, such
as Command-O, Option-↑ or F5, reaches only the first responder's `keyDown`, which in the sidebar
is the outline view's. The Edit menu's Select All, Undo, Redo, Cut, Copy and Paste have their own
actions, which the outline view (Select All) and `NSWindow` (Undo, Redo) answered for themselves.

The window always has a focused pane: `Layout.focused` is never empty, and a new or restored
window focuses its first pane. So "the focused pane or the first pane" is the window's focused
pane, `Tab.focusedPane`, whether or not its table has the keys.

## Decision

- **Keys.** The sidebar's list keeps Return and Esc, as before, and the plain and Shift-only keys
  a list uses: the arrows, Tab and Shift-Tab, the page keys and typing to select. A key with
  Command, Control or Option, or a function key, that a command of the focused pane takes goes to
  that pane's table's `keyDown`, as if the table had it. One no command takes stays with the list,
  as before.
- **Menu items.** Outside every pane's table and outside a text field, as in the sidebar, the path
  bar or the tab strip, the window controller takes every command's item and runs it on the
  focused pane's table, which also validates it, so an item is on exactly when it will act. In a
  text field only the window and tab commands' items work, as before.
- **Edit menu.** The window controller runs Select All, Undo, Redo, Cut, Copy and Paste on the
  focused pane's table. The sidebar's list, which selects one row at a time, says it doesn't
  answer Select All, so the item goes on to the window. `NSWindow` answers Undo and Redo ahead
  of its controller, and a text field's field editor doesn't answer them itself but relies on
  the window's. So the window undoes the typing with the field editor's undo manager while a
  text field has the keys, and passes Undo and Redo to its controller otherwise. In a text field
  the controller turns all six items off: the field and the window answer them first.
- **Where the keys stay.** A command run this way leaves the keys in the sidebar, as a command that
  redraws the window already did (0086). One that moves the keys itself still does: the filter
  field takes them for Filter, the rename field for Rename. Go to Folder's sheet hands them back
  to the window's first responder as it closes, so to the sidebar, the same rule as the palette's
  ([0087](0087-palette-window.md)). (Amended 2026-10-26, Dylan: "if sidebar has focus and you
  navigate between panes with keyboard shortcut, that should move focus from sidebar to that
  pane".) Focus Pane Left, Right, Up and Down and Focus Other Pane, run from outside the panes'
  tables by their chord, menu item or the palette, give the keys to the pane they focus. A Focus
  Pane key with no pane that way still moves the keys to the focused pane: the key asks for a
  pane, not the sidebar. A click in a pane already gave it the keys.
- **The focus ring.** (Added 2026-10-26, Dylan: "if sidebar is focused, the panes on right should
  remove focus indicator (but tab should still go back to the correct pane that did have the
  focus)".) While the keys are anywhere in the sidebar, no pane shows the focus ring
  ([0054](0054-tabs-in-window.md)), as no table shows its selection as active. `Layout.focused`
  doesn't change, so Tab, Esc and the commands still go to the focused pane, and its ring shows
  again as soon as the keys go back to a pane. The ring is the only mark of the focused pane: its
  path bar and status bar look the same in every pane.
- **Quick Look stays with the lists.** Space stays the sidebar's, and the Quick Look item is off
  outside a pane's table. The panel finds its data source up the responder chain from the keys,
  and takes its keys from the table that started it only while that table has the window's
  keys, so from the sidebar it would open empty and ignore its own keys.

## Alternatives considered

- **Put the focused pane's table in the sidebar's responder chain** — rejected: the chain is the
  view tree's, and a table after the outline view would also take the outline's own actions,
  such as `moveDown:`.
- **Send the sidebar every key it doesn't handle** — rejected: `NSOutlineView` handles or beeps
  at every key itself, so there is no "unhandled" to catch; the split has to be by key.
- **Quick Look from the sidebar on the focused pane** — rejected for now: it needs the window to
  serve as the panel's controller for the focused pane and the panel's key check to accept a
  table without the keys, a change to 0054's Quick Look rule beyond this step.

## Consequences

A Command, Control or Option chord that a pane command takes never reaches the outline view;
the others still do. With the
keys in the path bar or the tab strip under Full Keyboard Access, every command's menu item now
works, where 0054 left only the window commands on.
