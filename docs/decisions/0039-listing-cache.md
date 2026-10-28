# 0039. Listing cache: network volumes only, in memory and one plist per volume

- **Date:** 2026-10-22
- **Status:** accepted

## Context

B4 asks for a revisited SMB folder's rows within 16 ms on W4, and a share answers a first read in
tens to hundreds of milliseconds, or not at all while it hangs
([0038](0038-slow-volumes.md)). The rows have to come from listings kept from earlier visits, in
memory and across relaunches. A volume is named by its `VolumeIdentity` (device, mount point,
kind): two shares mounted one after the other at the same point are different volumes. The
project is pre-release, so stored data has one shape, with no version field or migration, and a
file of any other shape is discarded. Sort keys and folded names are derived data
([0013](0013-name-sort-key.md), [0028](0028-folded-names.md)) and `Listing` builds them in one
pass. Tests and bench mode must never read or write the user's Library folders.

## Decision

- **Network volumes only.** `ListingCache` keeps folders by `VolumeIdentity` and path, and
  ignores any volume whose kind is `.local`, which covers external disks: listing them again
  costs about what a cache read would. `ListingCacheStore.save` traps on a local volume.
  (Amended 2026-10-26: a share folder revisited in the same launch now shows the rows a pane
  last showed of it from `RecentListings` instead, in the move's turn
  ([0109](0109-recent-local-listings.md)). This cache still serves first visits and relaunches.)
- **What is kept.** `ListingCache.Folder`: the entries as the lister returned them and the date
  they were listed. Sort keys, folded names and kinds are rebuilt by `Listing` from the entries.
- **Memory.** An actor holding the `defaultVolumeCap` (8) most recently used volumes, each with
  every folder kept for it. Using a volume past the cap drops the least recently used one from
  memory; its file stays. A volume's file is read the first time the volume is used.
- **Disk.** One binary plist per volume in `<caches root>/listings/`, named by the SHA-256 of
  device and mount point, which together can be longer than a file name allows. The file also
  holds the device and mount point, and a file holding another volume is discarded. At most
  50 MB in all: after each write, the least recently written files are deleted until the folder
  fits. A volume that alone encodes to more than 50 MB isn't written, since `trim` would only
  delete it again at each write; that is logged once, until a save of the volume fits, and the
  other files and any older file of that volume are left as they are.
- **One shape.** Every key of the volume, folder and entry dictionaries must be there and no
  other: `size` for a regular file and for nothing else, as the lister reports it. A missing or
  extra key, a value of the wrong type, or bytes that aren't a plist fail the decode; the file
  is deleted, the reason is logged, and the lookup misses. Encoding an entry that breaks the
  `size` rule traps rather than writing a file that would be discarded on load: the lister never
  makes one, so it would be a bug.
- **Writes.** A save is written two seconds after the first unwritten one
  (`ListingCacheStore.writeDelay`), so saves meanwhile go out in the same write, through
  `AtomicWrite` on the store's actor, never the main thread (`dispatchPrecondition`). A load sees
  a save not yet written. `flush()` writes at once, for quitting. The clock is injected.
- **Roots.** `StoreRoots` names the caches and application support folders. `user()` puts them
  under the main bundle's ID and throws, with a message, when there is none; tests and bench mode
  pass temporary folders.

## Alternatives considered

- **Store sort keys and folded names** — rejected: they are derived from the names, and a change
  to the fold or key order would need a version field to invalidate them. Rebuilding is part of
  the timed B4 case.
- **One file per folder** — rejected: W4 has 3.1k folders, so thousands of small files and a
  directory scan to enforce the cap; a volume's folders are used together.
- **Key the file by mount point** — rejected: a different share mounted at the same point would
  read the first share's listings.
- **`Codable` with default decoding** — rejected: it ignores extra keys, so a file of another
  shape would be read in part.
- **Cache local volumes too** — rejected: no gain against a warm local listing, and more to
  keep current. Overturned for revisits by [0109](0109-recent-local-listings.md): Dylan,
  2026-10-26, "switching between two directories back and forth in column view still flashes.
  it should be immediate if we have already visited it". The listing's time wasn't the cost;
  the blank frames before it landed were.
- **Write on every save** — rejected: opening a folder of albums one after another would
  rewrite the volume's file each time.

## Consequences

A volume's whole file is decoded on its first use, so a volume near the 50 MB cap takes as long
as decoding that file before its first lookup answers; M2.3 should start that read when a pane
first lands on the volume. The memory cap counts volumes, not entries, so memory per volume is
unbounded: one volume with many large folders holds them all in memory. M2.3 picks an entry or
byte bound. Saves made in the two seconds before the app is killed
are lost unless the app calls `flush()` on quit. Lookups and stores are not wired to
`ListingService` or `Pane` yet; M2.3 does that and decides when a kept listing is replaced.

## Amendment: one file doesn't stop the trim (2026-10-27)

`trim` handles each file on its own: a file it can't delete, or whose size and date it can't
read, is logged and skipped, and the least recently written files after it are still deleted
until the folder fits 50 MB. A file whose size can't be read isn't counted. Before, the first
such failure ended the trim, so one undeletable file let the folder grow past the cap for good.
Files whose names aren't a volume file's are deleted before any attributes are read.

## Amendment: tag colors (2026-10-27, TG.2)

An entry with colored tags has a `tags` key, its color labels, and an entry without has none,
as `size` is there for a regular file only. An empty list, a repeated label or one outside 1 to
7 fails the decode ([0124](0124-tags-in-rows-and-preview.md)).
