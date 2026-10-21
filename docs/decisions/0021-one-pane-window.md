# 0021. One pane in a window: keys in the table, patches in the pane, watchdog by argument

- **Date:** 2026-10-21
- **Status:** accepted

## Context

M0.13 puts one pane in a window and wires it to the pieces built before it: the command registry
([0010](0010-command-registry.md)), the pane model ([0019](0019-pane-model.md)), the folder monitor
([0020](0020-folder-monitor.md)) and the stall watchdog ([0011](0011-stall-watchdog.md)). The plan
says which files do the work but not where a key becomes a command, who applies a monitor's
patches to the listing, what the pane shows while it loads, or when the watchdog runs.

## Decision

- **Keys.** `ListingTableView.keyDown` turns the event into a chord with `KeyChord(event:)` and
  looks it up in the registry. A bound key runs its command through the pane view controller,
  which finds the command's binding and runs it on its pane, and never reaches `NSTableView`. An
  unbound key goes to `super`. A double-click on a row runs Open through the same path, after
  selecting the row if it isn't selected.
- **Rows.** `Pane.stateVersion` goes up each time the state is set. `ListingViewController`
  reloads only when it has changed, so a selection change moves the table's selection without a
  reload (B6).
- **Patches.** `Pane.apply(_:at:)` takes the monitor's changes on the main actor. It patches a copy
  of the loaded listing off the main actor, one patch run at a time, and changes that arrive
  meanwhile wait for the next run. A patch that lands after the state changed (a load, a sort
  change, a navigation) is dropped and the folder is listed again. A change that arrives while a
  load is running, whatever the state, lists the folder again once that load ends, since the load
  may have read past the changed entry and its listing would undo the change. Over loaded rows
  the patch still applies, so the change shows at once. A change for another location is
  ignored, since a stopped monitor can report once more.
- **Monitors.** `PaneViewController` starts a `FolderMonitor` off the main thread each time the
  pane shows a new location, and hands it to `Pane.monitor` only if the pane is still there and
  no newer start was asked for; otherwise it stops it. A monitor that can't start is logged.
- **Loading.** A spinner, and for a folder that failed to list a line with the error, sit over
  the table. The table is never hidden: hiding the first responder moves focus to the next key
  view, and keys would stop reaching the pane after every navigation.
- **Denied folders.** A folder in the `denied` state (privacy protection, not Unix permissions;
  see [0019](0019-pane-model.md)) shows `AccessDeniedView` over the table in place of the error
  line: the folder's name, why, and a button that opens the Full Disk Access list through
  `SystemActions.openURL`. A folder Unix permissions keep the user out of gets the error line.
  The view reaches the system through `Pane.systemActions`, so a pane has one route to it. The
  table stays first responder, so Cmd-↑ goes back from a denied folder. The button takes focus
  only by Tab under Full Keyboard Access, as any button does; from there the pane's keys don't
  reach the registry until focus returns to the table. The view's strings are declared once, in
  `AccessDeniedView`.
- **Watchdog.** `--stall-threshold-ms <ms>` starts the watchdog on the main run loop in any build,
  so the UI bench can pass it to a release build. Without it, a debug build logs that the
  watchdog is off. Stalls and that line go to os_log under the bundle ID, since `open` hides the
  app's output. `scripts/dev` gets the argument and B10 from
  `scripts/bench --print-stall-arguments`.

## Alternatives considered

- **Route keys in the window or through the main menu** — not yet: there is one pane and no
  menu. The step that builds the main menu (M1) decides how key equivalents and the table share
  chords.
- **Patch on the monitor's queue, holding the pane's listing there** — rejected: the listing
  lives on the main actor, and a second copy on the monitor's queue would drift from it when a
  load or a sort change replaced the rows.
- **Hide the table while loading** — rejected: see Loading above.
- **Run the watchdog only in debug builds** — rejected: the UI bench (M0.15) counts stalls in a
  release build with the same argument.

## Consequences

A change that races a load costs one or two more listings after the load ends, however many
changes arrive during it. It is two when a patch started over loaded rows during the load lands
after the load's listing: the version check then fails during the follow-up load and marks the
folder for one more.

Over loaded rows during a reload, a patched entry flickers: it shows at once, disappears when the
reload's listing, read before the change, lands (which also drops a selection of that entry), and
returns with the follow-up load. A later fix could re-apply the patches applied during the load to
that listing, or keep the current rows until the follow-up load lands.

The monitor starts after the first load of a location has started, because `FolderMonitor` must
start off the main thread and the load shouldn't wait for it: on a share that stopped answering,
the monitor's `open` blocks. A file created after the lister has read past its place but before
the stream is up isn't shown until the next change or re-list in that folder. The window is the
monitor's start time, a few milliseconds on a local volume. Closing it means starting the
FSEvents stream from an event ID taken before the load (`sinceWhen`), which touches
`FileEventStream`, `FolderMonitor` and `Pane`; that is left until the gap shows up in use. The
`sinceWhen` fix covers only the FSEvents backend: a vnode watch has no event history, so a folder
on a network volume keeps the gap. The fix there is to list the folder once more when the monitor
attaches: at once if the first load has ended, or after it ends (`relistAfterLoad`) if it is
still running. It costs one extra listing per navigation on a vnode-watched volume.

The spinner shows at once, so a fast folder can flash it for a frame until the spinner delay in
`LoadTimeouts` lands. Each pane view controller builds nothing per key: the registry and the
bindings by ID are built once for the app.
