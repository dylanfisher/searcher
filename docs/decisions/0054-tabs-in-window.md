# 0054. Tabs in the window: own strip, a view tree per tab, first responder in the focused pane

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M3.5 binds the workspace model ([0042](0042-workspace-model.md)) to the window. Until now the
window showed one pane in a one-leaf layout ([0021](0021-one-pane-window.md)), and the tiling and
other-pane commands were kept out of `AppCommands.sets` because no view passed a workspace
([0044](0044-tiling-commands.md), [0047](0047-other-pane.md)). `tmp/behavior.md` asks for
Searcher's own tab strip with native window tabbing off, Cmd-T for a new tab, Ctrl-Tab,
Ctrl-Shift-Tab and Cmd-Shift-] / [ to switch tabs, Tab to focus the other pane, and Cmd-W to close
the pane, then the tab, then the window. Its key table at line 27 also lists "Cmd-W: close tab",
which the Tiling table at line 117 contradicts. `CommandContext` traps when its pane isn't the
selected tab's focused command pane, and menu validation builds a context, so model focus and the
first responder must never disagree. The workspace tells panes about focus and visibility
([0048](0048-pane-load-priority.md)).

## Decision

- **Commands.** `WindowCommands` holds New Tab (Cmd-T), Close Tab (Cmd-Shift-W), Show Next Tab
  (Cmd-Shift-], Ctrl-Tab) and Show Previous Tab (Cmd-Shift-[, Ctrl-Shift-Tab). Next and previous
  wrap at the ends and are off with one tab. A new tab takes the focused pane's folder, view mode
  and sort, as a split does. `AppCommands.sets` now holds `TilingCommands`, `DualPaneCommands` and
  `WindowCommands`.
- **Cmd-W is Close Pane**, as line 117 says; line 27 is superseded. Close Window is gone from the
  Window menu, and Close Tab gets Cmd-Shift-W, which `tmp/behavior.md` gives nothing else. Close
  Tab hands its `CloseResult` to the context's `didClosePane`, as Close Pane does. On
  `.workspace` the window closes; on `.pane` and `.tab` the window drops the views when it next
  shows the workspace.
- **The window shows the workspace after every command.** Each `PaneViewController` gets a
  `WindowLink`: the workspace, `tabBounds`, `didClosePane`, and a call after each command. The
  window then drops views of closed tabs and panes, makes views for new ones, puts the selected
  tab's `PaneLayoutView` in the window, marks the focused pane, moves the first responder, and
  sets the titles. It does nothing costly when nothing changed: `PaneLayoutView.show` returns at
  once for the same layout and views.
- **One view tree per tab.** Each tab keeps its `PaneLayoutView` and pane view controllers while
  it is open. A tab that isn't selected has its layout view out of the window, so switching back
  shows the same split, ratios, zoom and focus with no new views and no relisting beyond what
  `didGainFocus` does. Divider drags set the ratio on the tab (`PaneLayoutView.applyRatio`), which
  owns the layout.
- **Focus and first responder stay in step, both ways.** After each command the window makes the
  focused pane's table first responder, unless something in that pane already is, such as its
  filter field. The window is a private `NSWindow` subclass that reports every
  `makeFirstResponder`; when the first responder lands in another pane of the selected tab, by a
  click or the key view loop, the window focuses that pane through `Tab.focus`. Every focus move
  goes through `Tab.focus`, a tiling command or `Workspace.select`, so the workspace calls
  `didGainFocus` and `didLoseFocus` and sets visibility for each one.
- **Tab.** The table runs Focus Other Pane on Tab. The command is off with one pane, and a Tab
  key, with any modifiers, whose command is off or unbound goes to `NSTableView`, which moves the
  key view: with one pane Tab moves the key view as before, and Ctrl-Tab with one tab no longer
  beeps. The filter field routes `insertTab:` to the same command, so Tab there focuses the other
  pane too; with one pane the field moves the key view.
- **Focus Other Pane in the menu.** It is in the Window menu with no key equivalent. A Tab key
  equivalent would take Tab from the filter and Go to folder fields, since the menu sees the key
  first.
- **Shift-Tab stays unbound.** From the table it still selects the previous key view, which is
  how keyboard and VoiceOver users reach the path bar and the filter field now that Tab focuses
  the other pane.
- **The strip.** `TabStripView` is a segmented control, one segment per tab titled with its
  focused pane's folder, hidden with one tab. VoiceOver reads it as a tab group named "Tabs". The
  window title is the selected tab's focused pane's folder.
- **Native tabbing is off.** The window sets `NSWindow.allowsAutomaticWindowTabbing` to false and
  its own `tabbingMode` to `.disallowed`, so AppKit adds no tab bar and no tab items to the
  Window menu.
- **Menu items outside the tables.** Command items send `runMenuCommand:`, which only a pane's
  table implements, so with the keys in the filter field, the path bar or the tab strip they
  would be off and Cmd-W would do nothing. The window controller, at the end of the responder
  chain, takes the item for Close Pane, Close Tab, New Tab, Show Next Tab and Show Previous Tab
  and runs it on the focused pane's table. Other commands stay off there, so a text field keeps
  its editing keys, as 0037 asks.
- **Quick Look.** The panel runs the keys pressed in it on the table that started the preview.
  After the keys move, by a command or a click, the window has the panel find its controller
  again (`updateController`), and `QuickLookController` drops a key for a table that isn't its
  window's first responder, so a key in the panel never runs on a pane that lost the focus.
- **Key window.** `Workspace.isActive` follows the window's key status, from
  `windowDidBecomeKey` and `windowDidResignKey`. `Workspace.updatePanes` focuses the selected
  tab's focused pane only while it is active, so with two windows only the key window's pane
  loads as `.focused` ([0048](0048-pane-load-priority.md)).
- **The focus ring.** The focused pane gets a 2 pt ring in the keyboard focus color while another
  pane shows, not with one pane or while zoomed.

## Alternatives considered

- **Cmd-W closes the tab, as line 27 says** — rejected: the registry allows one command per
  chord, and line 117 gives the close order the tiling model was built for.
- **The model follows the first responder only through each table's `didBecomeFirstResponder`**
  — rejected: a column's table already uses that hook to move the trail's focus, and the filter
  field has no such hook. One window-level hook covers every view.
- **A Tab key equivalent on Focus Other Pane** — rejected: see above.
- **Bind Shift-Tab to Focus Other Pane as well** — rejected: it would leave keyboard users no key
  to reach the path bar and filter field.
- **Rebuild a tab's views each time it is selected** — rejected: new tables relist and lose
  scroll positions, and the step asks that hidden tabs keep their view controllers.
- **AppKit window tabs** — rejected by `tmp/behavior.md`: the strip shows workspace tabs, each
  with its own split tree, which native tabs can't hold in one window.
- **A separate callback on the context for Close Tab** — rejected: `didClosePane` already takes
  a `CloseResult`, and Close Tab reports the same cases.

## Consequences

Every command, ↓ included, runs the window's update after it. It compares dictionaries the size
of the pane count and the layout, which is small next to the row work; B6 with a split is M3.7's
to measure.

With the focus in the filter field, the path bar or the tab strip, only the window and tab
commands' items work, through the window controller. The other commands' items stay off there,
since the table isn't in those views' responder chain ([0037](0037-type-to-filter.md)).

`updateController` runs after every command and focus change while the Quick Look panel exists.
It walks the responder chain once; with no panel it is one check.

The ring's color is read when it is drawn on; a change of accent color while a split shows takes
effect at the next focus change. Closing a window with its close button leaves its workspace's
tabs to be freed with the window controller, as the one-pane window did (superseded: the
window now closes its panes, see [0057](0057-windows-and-tear-out.md)). Tabs have no close
button and can't be dragged; Close Tab and Close Pane close them.
