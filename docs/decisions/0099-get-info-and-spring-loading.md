# 0099. Get Info through Finder's Apple Events, and spring-loaded folders timed per row

- **Date:** 2026-10-24
- **Status:** accepted

## Context

CV.9 adds two Finder features. Get Info (⌘I) opens Finder's own Info window for each selected
item, or for the folder with nothing selected. Asking Finder means sending it Apple Events,
which wait for Finder's reply and, the first time, for the user to answer the Automation
(TCC) prompt; a busy Finder can take seconds. Spring-loaded folders open a folder row that a drag
hovers over, after the system's spring-loading delay, so the drag can go on inside it. AppKit
validates a drop on every pointer move, on the main thread, from the listing alone
([0071](0071-drag-and-drop.md)); packages are files ([0093](0093-packages-are-files.md)).

## Decision

### Get Info

- **The command.** `SystemCommands.getInfo`, "Get Info" on ⌘I, which nothing else took. It sits
  first in the File menu's Rename group and, in the row context menu, before Rename, with the
  `info.circle` symbol, as in Finder. It acts on the command pane, the focused column in column
  view, through `SystemActions.showInfo` with the same URLs Reveal in Finder takes: the selection
  in display order, or the folder with nothing selected. Finder's Get Info is never off, so the
  command has no `isEnabled`. It isn't in the menu for a click below the rows: that menu keeps
  the selection, so Get Info there would show the selection and not the folder.
- **`NSAppleEventDescriptor`, not `NSAppleScript`.** `NSAppleScript` is documented as main-thread
  only and compiles source on each use. The descriptor is built directly and
  `sendEvent(options:timeout:)` runs on any thread. The event is the one AppleScript sends for
  `open information window of item …`: `aevt/odoc` to `com.apple.finder` whose direct object is
  a list with one specifier per item, the `iwnd` property (from Finder's scripting dictionary) of
  the item at its file URL. The item is a `cobj` specifier of form `indx` with the URL as its
  data, as AppleScript sends it; a bare file URL as container gets -1728. One event opens every
  window; `misc/actv` then brings Finder to the front. A test checks the event's shape without
  sending it.
- **Off the main thread.** `WorkspaceSystemActions.showInfo` sends on a `BlockingCallThread`,
  since the wait can be long (the prompt waits for the user; the reply waits up to
  `finderTimeout`, 30 s), and on a GCD queue or the cooperative pool it would hold a worker.
  Tests inject the sender, so no test sends an Apple Event.
- **One request at a time.** While Finder hasn't answered a Get Info, another one does nothing
  and is logged. Pressing ⌘I again at a hung Finder then doesn't pile up events that all open
  windows once it wakes. Replacing the waiting request isn't possible: an event already sent
  can't be taken back from Finder.
- **The prompt doesn't use up the timeout.** The sender first asks for permission with
  `AEDeterminePermissionToAutomateTarget`, asking the user if needed, with no timeout, and sends
  the event only once that returns, so the 30 s start after the prompt is answered. A timeout
  (`errAETimeout`, -1712) is logged and not presented, whenever it happens: Finder keeps the
  event and opens the windows once it gets to it, so an alert would be wrong as often as not.
- **Automation permission.** `NSAppleEventsUsageDescription` is in `Info.plist`; without it
  macOS refuses the event without asking. `scripts/bundle` copies the plist as it is and signs
  without the hardened runtime, so no `com.apple.security.automation.apple-events` entitlement is
  needed. `errAEEventNotPermitted` (-1743) and `errAEEventWouldRequireUserConsent` (-1744) are
  presented as `AutomationDenied`, in the words of `AccessDeniedView`'s Full Disk Access
  explanation, with "Open Automation Settings" as the alert's first button, through Swift's
  `RecoverableError`. Any other failure, a timeout or an item that's gone, is presented as
  `InfoFailed` with Apple Events' or Finder's own message. Both are logged.
- **No Inspector.** Finder's Inspector (⌥⌘I) follows Finder's own selection, and its scripting
  dictionary has no way to point it at other items, so it isn't cheap; ⌥⌘I stays free.

### Spring-loaded folders

- **Which rows spring.** A row springs when a drop on it would go into it: Kind "Folder", for a
  drag the list takes (file URLs or promises), not into itself. `ListingViewController` works it
  out in `validateDrop` from the same `Drop` it already builds, so it reads nothing from the
  disk. Packages, apps among them, and files don't spring, as in Finder. Links don't spring
  either: Finder springs a link or alias to a folder, but telling one from a link to a file takes
  a read, and a drop on a link's row already goes to the pane's folder.
- **The delay and the setting.** The system's Spring-loading setting (Accessibility ▸ Pointer
  Control) writes `com.apple.springing.enabled` and `com.apple.springing.delay` (seconds) to the
  global domain; `NSEvent` has no API for them. `Settings.springLoadingDelay` reads them, through
  the app's suite, which reads through to the global domain, every time a drag reaches a new row,
  so a change applies to the next hover. Off reads as nil and nothing springs, Space included. A
  missing or malformed value reads as the system's default, 0.5 s, and is left alone, since the
  key isn't the app's.
- **Timed per row.** AppKit's `NSSpringLoadingDestination` times hovering per view, and a table
  is one view, so `SpringLoader`, one per pane shared by its list and every column, times each
  row itself on an injected clock: a new row starts the wait again and calls
  `resetSpringLoading()`, and leaving the row or the table cancels it. The table still adopts
  `NSSpringLoadingDestination` with `[.enabled, .noHover]` over a row that springs, so AppKit
  reports Space and a force click, which spring the row at once.
- **What springing does.** `Pane.springOpen`: in list view the pane moves into the folder; in a
  column the folder is selected, so its column opens at once ([0046](0046-column-view.md)), and
  that selection is no step of the selection history.
- **Going back.** Finder puts the window back where it was once a drag that sprang folders open
  ends, whether it dropped or was cancelled, as the step's brief describes it (not checked
  against Finder here); Searcher does the same through `Pane.springBack`. In
  list view the pane goes back to its folder with the selection it had, and the history goes back
  to what it was, so the folders sprung through are no Back steps. In column view each column
  still in the trail takes back its selection, left to right, and the focus goes back to its
  column. If something other than the drag moved the pane after the last spring (another folder,
  or another folder in a column the spring left), the pane stays. In list view the filter comes
  back too: moving into a folder clears it, so `SpringOrigin` keeps it.
- **No palette visits.** A spring and the way back count no visit in `FolderVisits`, so a drag
  that only hovers leaves the palette's frecency as it was. Since the pane always goes back,
  the user never stays in a sprung folder, so no folder of a spring is counted, the drop's
  target included.
- **Knowing the drag ended.** A list hears `draggingEnded` when the drag ends over it, after its
  drop, if any. A drag that ends elsewhere sends the pane nothing, so once the drag has left the
  pane's lists after a spring, `SpringLoader` checks the mouse button every 100 ms and goes back
  once it is up. It never goes back while the drag is over a list, so a drop is never made into a
  list that moved under it.

## Alternatives considered

- **`NSAppleScript`** — rejected: main thread only, so a slow Finder or the TCC prompt would
  block the UI.
- **One event per item** — rejected: a round trip and a possible error per item, where Finder
  takes a list.
- **`NSSpringLoadingDestination` timing alone** — rejected: it times the whole table, so moving
  from one folder row to the next wouldn't start the delay again.
- **Spring links after resolving them** — rejected: a `realpath` per hovered row on the main
  thread, or an asynchronous read that lands after the pointer moves; drops on links don't go
  into them either.
- **Stay in the sprung folder after a drop** — rejected: not what Finder does, by the brief. If
  Finder turns out to stay, `SpringLoader.dragEnded` has to learn whether the list took a drop.
- **Navigate back with `goBack`** — rejected: it leaves the sprung folders as Forward steps.

## Consequences

Get Info on a large selection opens a window per item, as Finder does, with no question first.
The first Get Info prompts for Automation; after a denial macOS never prompts again, and the
alert sends the user to System Settings. An ad hoc signature changes with every build, so the
Automation grant may need renewing after a rebuild, as Full Disk Access does. Whether AppKit
reports Space during a drag from another app depends on the drag server, which tests can't
reach; tests call the activation directly. If AppKit ever fails to send `draggingEnded` for a
drag that ends over a list, the pane stays in the sprung folder. A Get Info pressed while Finder
is busy is dropped, not queued; the user presses ⌘I again once Finder answers.
