# 0059. Move to Trash with FileManager.trashItem, one item at a time

- **Date:** 2026-10-22
- **Status:** accepted

## Context

Move to Trash must work on a selection of 1,000 items, report where each item went so Undo can move
it back, and leave Finder's Put Back working. Two APIs do this: `FileManager.trashItem`, one
synchronous call per item that returns the item's new URL, and `NSWorkspace.recycle`, one call for
many items that calls back on the main queue with a map from old to new URLs. Spike S7 trashed
1,000 files it created in a temp folder on the boot volume and on an attached APFS sparse image,
on a Mac17,6 (M5 Max, 48 GB, macOS 26.6.2), median of 3 runs each.

| API | Volume | 1,000 items (s) | Result URL folder | Put Back record |
|---|---|---|---|---|
| FileManager.trashItem | boot | 0.206 (max 0.284) | `~/.Trash` | within 3 s |
| NSWorkspace.recycle | boot | 0.224 (max 0.231) | `~/.Trash` | within 3 s |
| FileManager.trashItem | image | 0.210 (max 0.211) | `.Trashes/501` | within 3 s |
| NSWorkspace.recycle | image | 0.227 (max 0.230) | `.Trashes/501` | within 3 s |

"image" is the APFS sparse image; its `.Trashes/501` sits at that volume's root. Every run returned
1,000 result URLs (none nil), all of them existing and in the folder above, and left nothing in
the source folder.

"Put Back record" means the trash folder's `.DS_Store` held a `ptbL` entry for the item's name 3 s
after the call: 20 of 20 sampled items had one, against 1 of 20 right after the call, for both
APIs. Finder writes those entries on its own.

Not measured yet:

- Both APIs on W7 exFAT and on the SMB share (`/Volumes/main/searcher-m4`): whether each returns
  a result URL or an error where the volume has no trash. This can change only which API the
  engine uses on those volumes, and whether it asks for delete-immediately there.
- Put Back in Finder for an item trashed by each API from the boot volume. This can change only
  which API the engine uses, if one of them fails.

## Decision

The engine trashes each item with `FileManager.trashItem` on a background queue and keeps each
returned URL for Undo. Items that can't be trashed are reported per item, and the user is asked
whether to delete them immediately.

The numbers support this choice. The two APIs differ by 8% on 1,000 items (0.206 against 0.224 s
on the boot volume, 0.210 against 0.227 s on the image) and return the same URLs and Put Back
records. `trashItem` costs 0.2 ms per item and reports each one on its own.

## Alternatives considered

- **`NSWorkspace.recycle`** — rejected: 0.224 s for 1,000 items against 0.206 s, the same result
  URLs and Put Back records, but one completion for the whole batch on the main queue, so there
  is no per-item progress or cancel and errors arrive as one.
- **Finder through Apple Events** — rejected: needs the Automation permission and Finder running,
  and the Put Back records it would give already appear for both APIs.

## Consequences

Undo of Move to Trash moves the items back from their result URLs, without Finder. Trashing 1,000
items takes 0.21 s, so a progress display rarely shows for it; the per-item loop still checks
cancel between items. Volumes without a trash need the delete-immediately prompt; which volumes
those are comes from the exFAT and SMB runs.

What would change this decision:

- `NSWorkspace.recycle` taking under half the time of the per-item loop for 1,000 items would make
  the engine batch with it and give up per-item progress. It took 109% of the loop's time.
- Put Back failing in Finder for one API but not the other picks the one that works.
- `trashItem` failing on the share or exFAT while `recycle` succeeds picks `recycle` for those
  volumes.
