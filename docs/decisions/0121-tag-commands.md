# 0121. Finder's tag commands: dots in the row menu, a queued toggle, undo that restores each list

- **Date:** 2026-10-27
- **Status:** accepted
- **Builds on:** [0065](0065-operation-queue.md) (the queue),
  [0067](0067-operations-panel.md) (the panel), [0072](0072-undo.md) (undo),
  [0070](0070-context-menus-and-services.md) (the row menu),
  [0010](0010-command-registry.md), [0060](0060-menu-items-for-every-command.md),
  [0106](0106-primary-and-alternate-shortcuts.md) (commands and their menus),
  [0110](0110-interaction-states.md) (control states)

## Context

Dylan decided on 2026-10-27 to keep ⌘I opening Finder's own Info window
([0099](0099-get-info-and-spring-loading.md), unchanged) and not to build a Get Info panel of
our own, and asked instead for Finder's tag commands: the row menu's tag dots, the File menu's
tags, through the queue and undoable. His rule for undo: "Undo must have no edge cases."

The records this has to fit:

- 0065: "**Beside the lanes.** Rename, new folder, trash, delete immediately, and a move within
  one volume run as soon as they are planned, since each is one quick call per item." and
  "Every operation in a lane — rejected: a rename would wait behind a 20-minute copy to the same
  disk, and it takes one call." Also: "An operation is refused at once, with the path, if it
  would change a path that an unfinished operation reads or changes".
- 0067: "**One queue for the app.**" and "**Each operation belongs to the window that queued
  it**", so a failed toggle is listed in its window's panel.
- 0072, one history fed as operations finish: "it follows every operation the queue finishes,
  so Undo in any window undoes the last change made in any of them."
- 0072, what makes an entry: "Every record with a change makes an entry … A cancelled or failed
  operation's entry holds what it did change; one that changed nothing … makes none."
- 0072, titles: "The items read "Undo Move 3 Items" and "Redo Move 3 Items" … The operations
  panel shows the same title."
- 0072, partial undo (UN.1): "An undo that changed some of its entry, failed or cancelled part
  way, splits it: what it changed goes on the other side as the entry Redo (or Undo) reverses,
  and what it didn't change stays in the entry's place to undo again".
- 0072, keep or drop: "An undo that failed and changed nothing keeps its entry only when every
  error can clear without the user losing an item (`FileOperation.canClear`)" — `exists`,
  `notTheSameItem`, `unreachable` and a missing outer folder — "kept once (`isRetry`)".
- 0072, check first: "If any source is gone, is another item than the recorded one
  (`notTheSameItem`) … nothing runs and the operation fails with one error per path".
- 0072, consequences: "a new change kind must say how it is reversed, and how
  `UndoHistory.remainder` keys its reversal."
- 0070: "`ContextMenuBuilder` builds every context menu from a list of `CommandID`s and
  separators."
- 0038: every blocking call on a share runs on a `BlockingCallThread`, "a `Thread` started for
  that one call".

## What Finder does, and how it was found

- **Edit menu titles.** Finder's own strings (`LocalizableMerged.strings` in Finder.app's
  `en.lproj`, and FinderKit's `LocalizableMerged.loctable`) hold "Undo Add Tag “^0”",
  "Redo Add Tag “^0”", "Undo Remove Tag “^0”" and "Redo Remove Tag “^0”", beside "Undo Edit
  Tags" and "Undo Remove All Tags". So a toggle's entry is "Add Tag “Red”" or "Remove Tag
  “Red”", with no item count; not "Tag 2 Items".
- **The menu's line.** Finder's context menu strings key `N160` "Tags…" and `N160.1` "Remove
  Tag “^0”": the line under the dots names what a click on the dot under the mouse does.
- **Which dots.** Finder shows the user's favorite tags (`defaults read com.apple.finder
  FavoriteTagNames`: here "", Red, Orange, Yellow, Green, Blue, Purple, Gray). That list is an
  undocumented key of another app's preferences, it holds names only, and a custom favorite's
  color isn't in it, so the app couldn't draw that dot. The dots are Finder's seven standard
  color tags in Finder's order, which is also its default favorites list.
- **Mixed selections.** Finder wasn't driven: builder rule 7 forbids taking focus or showing
  windows on the main display, which Finder's menu would. The rule follows Finder's strings
  and AppKit's mixed state: a dot whose tag some selected items have shows a dash, and a click
  adds the tag to the rest, as clicking a mixed checkbox turns it on; only a dot whose tag
  every item has shows a check and removes it, and only that one reads "Remove Tag “Red”",
  which is the one hover title Finder has a string for. **To check by hand** (below).
- **Colors.** Finder keeps an item's tags in `com.apple.metadata:_kMDItemUserTags`, a binary
  property list of entries, each a name and its label number: `Red\n6`, `Work\n4`, or a bare
  name for a tag without a color. The supported API, `NSURL`'s `tagNamesKey`, reads and writes
  names only: written back, `["Work\n4", "Plain\n0"]` plus Red became `Work\n0`, `Plain\n0`,
  `Red\n6`, since it takes each name's color from the user's tag list, and Work, whose color only
  the item held, lost its 4 (TG.1 review). `NSURL` also sets the legacy color label in
  `com.apple.FinderInfo`'s `fdFlags` to the last colored entry's, and removes a `FinderInfo` left
  all zero: written `["Blue", "Plain"]` the label is 4, `["Blue", "Red"]` 6, `["Plain"]` none.
  Spotlight's importer takes the entries as they are: `mdimport -t -d2` on a file written raw
  with `Work\n4`, `Red\n6` and `Plain` lists exactly those under `_kMDItemUserTags`.

## Decision

- **Reading and writing: the attribute itself.** `FinderTags` in Base reads and writes the
  entries of `_kMDItemUserTags` with `getxattr` and `setxattr`, off the main thread
  (`preconditionOffMain`), and sets `FinderInfo`'s color label as `NSURL` does. Every entry is
  written back exactly as read, so a tag that stays keeps its color, whether or not the user's
  tag list has it (`entriesAreWrittenExactlySoEachTagKeepsItsColor`); `NSURL` reads the result
  back by name, as Finder and Spotlight do. An empty list removes the attribute, as Finder leaves
  an untagged item, and an empty attribute reads as no tags.
- **Errors.** A read-only or locked file refuses with `EACCES` or `EPERM`, `permissionDenied`;
  a missing item is `ENOENT`, `sourceGone`; a volume without extended attributes gives
  `ENOTSUP`, `other`. A read whose size changed between asking and reading, `ERANGE`, as when
  another app wrote the tags in between, is tried once more; a second `ERANGE` is `other`. An
  attribute that isn't a list of strings is `other`.
- **Symlinks, as `NSURL` does them.** A symlink's tags are its target's: the attribute is read
  and written through the link. Its color label goes in the link's own `FinderInfo`, which
  `NSURL` writes with the alias flag a symlink reports, `kIsAlias` (0x8000), so a link tagged
  Blue has `fdFlags` 0x8008 and the target has none; cleared, the link keeps 0x8000. Found by
  setting `tagNamesKey` on a link in a scratch run
  (`aSymlinksTagsAreItsTargetsAndItsLabelIsItsOwn`).
- **A label that can't be set.** The tags are written first, then the label. If the label
  fails, the tags are put back as their bytes were and the item fails with the label's error,
  having changed nothing, so nothing goes unrecorded. If the tags can't be put back either,
  they stay written: the item fails with the label's error and its change is recorded, so undo
  can still reverse it (`aLabelThatCantBeSetPutsTheTagsBack`,
  `aLabelThatCantBeSetWithTagsThatCantBePutBackReturnsItsError`,
  `tagsWrittenWithoutTheirLabelAreRecordedAndUndone`). Either way no change on disk is left
  out of the record.
- **The operation.** `FileOperation.toggleTag(tag, on: paths)`, with a `FinderTag`. Its plan
  reads every item's tags (`OperationPlan.addsTag`): when some item it could read lacks the tag,
  the toggle adds it; when every one has it, the toggle takes it off each. Each item is read
  again as it runs and changed from what is there then, so a tag another app added after the
  plan read it stays, unless it lands in the moment between that read and the write. An item
  that already has the tag, in any color, or lacks it, isn't written or recorded. An added tag
  is the standard entry, `Red\n6`; a removal takes off every entry of that name. An item whose
  tags can't be read or written fails alone with its path and the others run, as for any
  operation. A change records `.tagged(path, from: old entries, to: new entries)`, each name
  with its color, and the item's identity as any change does.
- **Beside the lanes, not in a volume's lane.** The brief said the volume's lane; 0065 puts one
  quick call per item beside the lanes, and a tag write is one `setxattr`. In a lane, a click on
  a dot would wait behind a 20-minute copy to that disk, which 0065 rejected for rename. Items
  on two volumes need nothing more: each item is its own call. The toggle changes its items'
  paths for the refusal check, so it is refused while a copy reads one of them, and the reverse.
- **Undo restores each list exactly.** The undo step `.retag(path, from: the entries the change
  left, to: the entries before)` writes the whole earlier list, so order, colors and every other
  tag come back as they were, and an item that had the tag before keeps it: the toggle never
  recorded it. Redo is the undo of the undo's record, as 0072 has it, and checks the same way.
  `UndoHistory.remainder` keys a `.tagged` change's reversal by its path in comparable form and
  its two entry lists swapped, so a change matches only the undo that wrote its own lists back,
  with each path read once.
- **No silent clobbering.** Finder's undo of a tag doesn't say what it does when another app
  changed the tags since; 0072's check-first rule decides it. The undo's check reads each item's
  entries, and if any isn't the list the change left, colors included, nothing runs and that item
  fails with the new reason `tagsChanged`, naming it. The run reads each item again just
  before its write, which narrows the time another app's change could be overwritten to the
  moment between that read and the write; it doesn't close it, since no call reads and writes
  an extended attribute as one step. `tagsChanged` can clear (`canClear`): the user may set the
  tags back. So the entry is kept once, as for `notTheSameItem`; the next try that fails drops
  it.
- **Edge cases**, each with its test in `FileOperationTagTests` unless named:
  1. Mixed selection: added to the items without it; undo leaves the items that had it with it
     (`aMixedSelectionGetsTheTagAndUndoLeavesItOnItemsThatHadIt`).
  2. Every item has it: taken off each; undo puts back each exact list, order included
     (`aTagEveryItemHasIsTakenOffEachAndUndoPutsBackTheExactList`).
  3. Two files, undo, redo, with Finder's titles
     (`aTagAddedToTwoFilesUndoesAndRedoesAsFinderNamesIt`).
  4. A read-only file in the selection: it fails in the queue with `permissionDenied`, naming
     it, and the entry holds the items that changed (`aReadOnlyFileFailsAndTheOthersStayUndoable`).
  5. Tags changed by another app since: the undo changes nothing, names the item, and keeps the
     entry once (`tagsChangedSinceFailTheUndoAndChangeNothing`).
  6. An item renamed or deleted since: `sourceGone` naming it, nothing changes, and the entry is
     dropped, as 0072 drops a move whose item is gone; Finder can't find it either. A rename
     made in the app is a later entry and undoes first
     (`aTaggedItemRenamedSinceFailsTheUndoAndDropsTheEntry`).
  7. An undo whose write fails for one item after the check: the rest is undone and goes on
     Redo, the failed item stays on Undo to try again, and Redo later puts back both halves
     (`anUndoFailingForOneItemKeepsItToUndoAgain`).
  8. Items on two volumes, the startup disk and an HFS+ image: one toggle, one entry, undone
     and redone together (`itemsOnTwoVolumesToggleUndoAndRedoTogether`).
  9. A toggle that changed nothing makes no entry (`aToggleThatChangedNothingMakesNoEntry`).
  10. A tag whose color only the item holds, `Work\n4`, keeps it through the toggle, undo and
      redo (`aTagAddedToTwoFilesUndoesAndRedoesAsFinderNamesIt`); a color changed by another app
      since fails the undo (`aColorChangedSinceFailsTheUndo`).
  11. Redo after the tags changed since: it refuses as undo does, and runs once they are set
      back (`tagsChangedSinceFailTheRedoAndChangeNothing`).
  12. A 120-item toggle whose undo fails for every seventh item keeps exactly those to undo
      again (`aLargeToggleUndoneInPartKeepsTheItemsThatFailed`); the remainder of a 400-item tag
      entry reads each path once (`theRemainderOfALargeTagEntryReadsEachPathOnce`).
- **Commands.** `TagCommands`, one command per standard tag: "Red Tag" and so on, ids
  `tag.red`…, no default chords, off where Move to Trash is off (`canChangeSelection`). Seven
  fixed tags make seven static commands, so the registry needs no per-tag dynamic commands, and
  each shows in the palette and in Shortcuts like any command. Titles name the tag, not the
  action, as View's toggles name the setting, since whether a run adds or removes is known only
  once the plan reads the items. The File menu ends with a Tags submenu, where Finder puts Tags…
  and its dots; each item shows its tag's color.
- **The row menu.** After Share…, where Finder puts them, `ContextMenuBuilder.Item.tags` adds
  `TagDotsView`: the seven `TagDotButton`s and Finder's line under them, "Tags" at rest and the
  hovered dot's action, "Add Tag “Red”" or "Remove Tag “Red”". The view reads the
  selection's tags with `TagCommands.tags(of:)` on a `BlockingCallThread` as the menu is built;
  on a share that stopped answering the read never lands and the dots stay plain, and a click
  still works, since the toggle reads again. A click closes the menu and runs the tag's command
  on the clicked table. The dots are turned on as the menu opens, while the command can run,
  and a press that reaches a dot turned off since does nothing (`aDisabledDotDoesNothing`).
  A dot takes a press inside the circle it grows to under the mouse, 16 points, or within 2
  points of it, and not in the button's corners, both where the window looks for the view under
  the mouse and in the button's cell, since AppKit's own cell may take none on a button with no
  title, image or bezel (`aPressTakesTheDotInItsCircleAndNotInACorner`).
- **Dot states** (0110): at rest a 12-point circle in the tag's color
  (`NSWorkspace.fileLabelColors`) with a darker rim, and a white check for all, a dash for some;
  under the mouse it grows to 16 points and shows + or ×; pressed, it darkens a quarter toward
  black; disabled, it fades to 35% and shows no hover; with the keys, a round focus ring.
  Each dot is a button VoiceOver names by its action, "Add Tag “Red”", or by the tag's name
  until the items' tags are read; the row is a group named "Tags".
- **Tags…: not built.** Finder's Tags… opens a token field with suggestions from every tag in
  use, which needs the tag list Finder keeps privately and a popover editor; not cheap.
- **Refresh.** A tag change is an extended-attribute change, which FSEvents reports
  (`kFSEventStreamEventFlagItemXattrMod`, already one of the flags `FileEvent.modified` takes;
  `aTagChangeNamesTheFileAsModified`), so the folder's monitor patches the item. Its entry is
  the same as before, since tags change no listed field, and the column preview kept its read.
  The pane now notes the names each landed patch updated (`Pane.lastPatchedNames`), and the
  preview reads its file's info again when a patch named it since its read started
  (`aPatchNamingTheFileWithItsEntryUnchangedReadsItAgain`). No second mechanism: the same
  patch refreshes the preview for a tag set in Finder.

## Alternatives considered

- **Finder's favorite tags from `com.apple.finder`'s `FavoriteTagNames`** — rejected: an
  undocumented key of another app, names without colors for custom tags.
- **Decide add or remove in the command, from the dots' read** — rejected: the command runs on
  the main actor and can't read the disk, and the read may not have landed; the plan reads off
  the main actor and the dots use the same rule.
- **Undo removes the one tag, or adds it back** — rejected: it loses order and can't tell an
  item that had the tag from one the toggle gave it; restoring the recorded list can.
- **Undo overwrites whatever tags are there** — rejected: it silently undoes another app's
  change, which 0072's check-first rule refuses for every other change.
- **`NSURL`'s `tagNamesKey`** — dropped (TG.1 review): it writes names only, so a tag whose
  color only the item held lost it on every toggle, and undo couldn't bring it back.
- **Toggles in the destination volume's lane** — rejected (above, 0065).
- **One command per action, Add and Remove, per tag** — rejected: fourteen commands for what
  Finder does with seven dots.

## Consequences

The tag names are English. On a Mac in another language the standard tags have that language's
names, and "Red" written there would be a tag of its own without a color; when the app is
localized, the names come from `NSWorkspace.fileLabels`. A dot's state is read once per menu,
one `getxattr` per selected item on its own thread, and a click reads every item again in the
plan and once more as it runs. The attribute's format is Finder's, not a published API; if a
later macOS changes it, a read that isn't a list of strings fails the item with `other`.
Folder tagging conflicts, by path, with any operation inside the folder, as a rename of the
folder would. Each patch keeps a set of the names it updated.

**To check by hand:** in Finder, select two files, one tagged Red; right-click and compare the
red dot (dash or check) and what a click does with the app's; tag a file from the app and see
its color in Finder, and that a custom tag colored in Finder keeps its color when the app
adds Red; Edit ▸ Undo in Finder after a tag click shows "Undo Add Tag “Red”".

## Amendment: the dots, tested from a press (2026-10-27, TG.2)

Tests now build the menu from a press sent through the app's queue, onto every part of a
row's name cell, and find the dots shown and colored; why Dylan saw none wasn't found
([0124](0124-tags-in-rows-and-preview.md)). The check showed upside down, since a button is
flipped; it points down now. The dots' colors come from `NSColor.tagLabel`, which a row's dots
and the preview's pills share.
