# 0105. Trash and put back an item whose ACL denies deleting it, keeping the ACL

- **Date:** 2026-10-26
- **Status:** accepted
- **Amends:** [0059](0059-trash.md): "The engine trashes each item with `FileManager.trashItem` on
  a background queue and keeps each returned URL for Undo. Items that can't be trashed are
  reported per item", and its consequence "Undo of Move to Trash moves the items back from their
  result URLs, without Finder."

## Context

~/Downloads carries the ACL entry `0: group:everyone deny delete`. Duplicate copies ACLs, as
Finder's does, so "Downloads copy" carries it too. Dylan moved that copy to the Trash and the
operations panel said "There's no permission to change “/Users/dylanfisher/Downloads copy”."

The entry denies deleting the item, and `rename(2)` of an item counts as deleting it from its
folder, so any move of the item fails with `EACCES`: `mv` of it fails, a move of the files in a
folder carrying it doesn't. `FileManager.trashItem` and `NSWorkspace.recycle` both fail with a
permission error and ask nothing (research, 2026-10-25). The owner can remove the entry without
a password.

Finder, asked over osascript on 2026-10-26 to `delete` a scratch folder given the entry with
`chmod +a "group:everyone deny delete"`: the folder went to ~/.Trash with no prompt and no
password, and in ~/.Trash it still carried the `group:everyone deny delete` entry.

## Decision

- **Trash:** `Trasher.trash` calls `trashItem`. When that is refused for permission and the
  item's ACL has entries that deny `delete`, it sets the ACL without those entries, calls
  `trashItem` again, and sets the whole ACL as it was on the item in the Trash. The item ends as
  Finder leaves it. The ACL is read and set with `acl_get_link_np` and `acl_set_link_np`, which
  don't follow a symlink, as `trashItem` doesn't.
- **Put Back:** the undo of a trash, and the put back of a replaced item when its replacement
  fails, move the item out of the Trash with `Trasher.putBack`. It is `FileMover.move` with the
  same handling, since the entry refuses the move out as it refused the move in. The queue's
  `FileSystem` has `putBack` for it beside `move`.
- **Who:** only the owner can set an item's ACL, and nobody can on a locked (`uchg`) item. When
  setting it fails, the item stays where it is with its ACL, and the first refusal is the item's
  error, as before this record. A refusal of an item without a deny-delete entry is thrown at
  once.
- **Failure:** when the second call fails too, the whole ACL is set back on the item where it is
  and the first refusal is the item's error. An item is never left without its entries. An ACL
  that can't be set back after the move is the item's error, with the path the item is at now.

## Alternatives considered

- **Remove the whole ACL and set it back** — rejected: removing only the deny-delete entries
  leaves the item's other entries in force for the moment it moves, and costs a dozen lines.
- **Finder through Apple Events** — rejected for the reasons in 0059: the Automation permission
  and Finder running.
- **Ask first** — rejected: Finder doesn't.

## Consequences

The item is without its deny-delete entries for the length of one `trashItem` or `rename` call.
Only trash and put back go past the entry: a plain move or rename of such an item still fails
with no permission. Finder asks before trashing a locked item; this record doesn't change how a
locked item fails.

What would change this decision:

- Finder asking for a password or a confirmation for an item it doesn't own, or for one in a
  folder that denies `delete_child`: then the engine asks the same way.
- Finder moving or renaming such an item without asking: then `FileMover.move` gets the same
  handling.
