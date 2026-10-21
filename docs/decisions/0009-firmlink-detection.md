# NNNN. Find firmlinks by their SF_FIRMLINK flag

- **Date:** 2026-10-20
- **Status:** accepted

## Context

`getattrlistbulk` reports a firmlink's stub on the read-only system volume, so `/Applications` and
`/Users` at `/` show the stub's mtime instead of the data volume folder's, which `FileManager` and
`stat` report ([0003](0003-enumeration.md)). The lister has to find those entries and `stat` them.
Firmlinks aren't only at a volume root: `/usr/local` and several folders in `/System/Library` are
firmlinks too (`/usr/share/firmlinks` lists them).

## Decision

The lister reads `ATTR_CMN_FLAGS` with every entry and calls `fstatat` for any entry with
`SF_FIRMLINK` set, in any folder. Entries the bulk call returns without a type or mtime, or a
regular file without a size, get the same `fstatat`.

## Alternatives considered

- **`stat` every entry of a folder that is a volume root** — rejected: misses `/usr/local` and the
  `/System/Library` firmlinks, and needs its own check for being a volume root.
- **Read `/usr/share/firmlinks`** — rejected: a second copy of what the flag already says, and the
  file's format isn't documented.

## Consequences

Reading flags costs 4 bytes per entry. Hidden (`UF_HIDDEN`) and dataless (`SF_DATALESS`) can come
from the same field later. Mount points still differ from `FileManager`: the bulk call reports the
folder the volume is mounted on, so `/dev` at `/` and each volume in `/Volumes` show that folder's
mtime. A `stat` there would cross into the mounted volume, which on a share that has gone away
blocks, so it is left as is until a step needs mount-point dates.
