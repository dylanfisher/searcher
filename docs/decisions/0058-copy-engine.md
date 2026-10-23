# 0058. Copy with copyfile(3), cloning when the volume allows

- **Date:** 2026-10-22
- **Status:** accepted

## Context

Copy and move between panes need a progress bar, a cancel that stops within a frame, a pause, and
the metadata Finder keeps: xattrs, Finder tags, quarantine, ACLs, mtime, symlinks and packages.
Dylan copies between internal APFS, external disks (W7: APFS and exFAT) and an SMB share. Spike S7
measured `copyfile(3)` (`COPYFILE_ALL`, with and without `COPYFILE_CLONE`, and with an 8 MiB block
size), `FileManager.copyItem`, and a read/write loop with 1 MiB chunks that copies metadata
afterwards with `copyfile(COPYFILE_METADATA)`. The workloads were a W8 tree (4 × 2 GiB plus 20k
files of 50-150 KB) and its parts, from the boot volume to an attached APFS sparse image, on a
Mac17,6 (M5 Max, 48 GB, macOS 26.6.2), source in the page cache. A first pass ran 3 runs of each
case; a second pass (15:59-16:18, copy test only) ran 5. Numbers are medians; MB is 10^6 bytes.
The table is the 3-run pass.

| Method | W8 MB/s | 2 GiB file MB/s | 20k small files/s | Progress every | Cancel latency |
|---|---|---|---|---|---|
| copyfile ALL | 453 | 1175 | 4865 | 1 MiB, 0.53 ms | 1.9 ms (max 28) |
| copyfile ALL + CLONE | 407 | 1197 | 1907 | 1 MiB, 0.50 ms | 1.1 ms (max 60) |
| copyfile ALL, 8 MiB blocks | 426 | 1250 | 1319 | 8 MiB, 6.6 ms | 2.6 ms (max 5.7) |
| FileManager.copyItem | 411 | 1206 | 1354 | per item only | not possible within a file |
| read/write loop, 1 MiB | 656 | 1351 | 1314 | 1 MiB, 0.14 ms | 12.6 ms (max 13) |

Progress and cancel columns are for the 2 GiB file, with the cancel sent about 0.45 s into the
copy. Run-to-run spread is wide. On W8 the loop ran 387-781 MB/s and `COPYFILE_ALL` 432-923. On
20k small files `COPYFILE_ALL` ran 131-487 MB/s and `ALL + CLONE`, which does the same work
across volumes, ran 138-312. Three runs don't settle a ranking inside those ranges.

The 5-run pass, same machine, medians with the range in parentheses:

| Method | W8 MB/s | 2 GiB file MB/s | 20k small files MB/s |
|---|---|---|---|
| copyfile ALL | 801 (414-1119) | 795 | 335 (103-495) |
| copyfile ALL + CLONE | 419 | 792 | 187 |
| copyfile ALL, 8 MiB blocks | 422 | 832 | 130 |
| FileManager.copyItem | 469 | 1252 | 139 |
| read/write loop, 1 MiB | 388 (366-883) | 1159 | 128 |

The loop's W8 lead in the 3-run pass reversed: it is about half of `COPYFILE_ALL` here. Runs to
the image swing about 2× from run to run, so neither pass ranks the two on W8 throughput.
`COPYFILE_ALL` is ahead of the loop on 20k small files in both passes (486 and 335 against 131
and 128). FileManager's longest callback gap on W8 was 2.92 s in this pass.

Not measured yet:

- Throughput, progress and cancel on W7 APFS and W7 exFAT, and on the SMB share (W8 shape to
  `/Volumes/main/searcher-m4`; a W4 album and a 2 GB folder from the share to local). These can
  change only the 8 MiB-block and read/write-loop options below.
- A 60 s pause in the callback on SMB. It can change only how pause works on network volumes.
- A server-side copy within one share. It can change only how same-share copies are made.

What the spike measured, independent of timing:

- `copyfile` calls its status callback after every block: 1 MiB by default (2048 calls for the
  2 GiB file), or the size set with `COPYFILE_STATE_BSIZE`. A recursive copy also calls it at the
  start and end of each file (40000 calls for 20k files), so cancel is checked between small
  files too.
- Returning `COPYFILE_QUIT` stops the copy at the next block. A cancelled single-file copy
  removes its partial file (nothing left in any `copyfile` variant). A cancelled recursive copy
  leaves the files already copied: 3476-5031 files, 345-505 MB, after 1-4 s of the 20k-file
  tree, for every method.
- Blocking in the callback pauses the copy: a 2 s block left the destination unchanged and the
  file completed intact afterwards, for every `copyfile` variant and the loop.
- `FileManager.copyItem` reports nothing during one file and can't be cancelled inside it. Its
  delegate runs once per item, so on W8 the longest gap between callbacks was 2.87 s (a 2 GiB
  file), against 55 ms for `copyfile`.
- A cancelled read/write loop leaves its partial file: 520 MB after a 2 GiB cancel. The loop
  would have to delete it.
- Same-volume `COPYFILE_CLONE` and `FileManager.copyItem` clone every file, including each file of
  a recursive copy: no space used and `EF_MAY_SHARE_BLOCKS` set. A 2 GiB file clones in under
  1 ms and 20k files in 1.5-1.6 s. `COPYFILE_ALL` without `CLONE` copies the bytes (2048 MB used)
  and took 2.4 s on the boot volume and 17.5 s on the image's own volume.
- Without `COPYFILE_NOFOLLOW`, a recursive `COPYFILE_ALL` follows symlinks and fails on a dangling
  one with `ENOENT`. `COPYFILE_CLONE` implies no-follow.
- Every method kept xattrs, Finder tags, quarantine, the ACL, mtime to the nanosecond, mode, the
  hidden flag, symlinks (also dangling) and the package. None kept the creation date: the copy's
  creation date became its mtime.

## Decision

The copy engine copies each top-level item with `copyfile(3)` and
`COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW`, recursive for folders, on a background queue.
The status callback records bytes for progress, returns `COPYFILE_QUIT` to cancel, and blocks to
pause. Afterwards the engine sets the creation date with `setattrlist`, and on cancel it removes
the files of the item it was copying.

Throughput does not decide it: the two passes rank `copyfile` and the loop in opposite orders
on W8. The choice rests on four points. It is the only option that clones on one volume (20k files
in 1.6 s against 2.4-17.5 s). A cancel removes the half-copied file. It is ahead on small files in
both passes. Finder's metadata and AppleDouble handling come from the system in one call.

## Alternatives considered

- **`FileManager.copyItem`** — rejected: no progress or cancel inside a file, so a 2 GiB file
  shows no movement for up to 2.87 s and can't be stopped. Its W8 throughput was 411 MB/s against
  407 for `copyfile` with `CLONE` and 453 without, and it clones on the same volume as
  `COPYFILE_CLONE` does.
- **Read/write loop with `copyfile(COPYFILE_METADATA)` afterwards** — rejected: its W8 median
  was 656 MB/s in the 3-run pass (453 for `copyfile`) and 388 in the 5-run pass (801), so it has
  no steady gain. It has no clones, leaves its partial file on cancel (520 MB after a 2 GiB
  cancel), ran 131 and 128 MB/s on 20k small files against 486 and 335, and symlinks, folders and
  partial files are all ours to handle. It gives the same progress and cancel as the callback.
- **`copyfile` with 8 MiB blocks** — rejected: 426 MB/s on W8 against 453 at the default, and
  progress arrives every 8 MiB (6.6 ms) instead of 1 MiB (0.5 ms).

## Consequences

The engine needs no copy loop of its own and gets same-volume clones, Finder's metadata and
AppleDouble handling on exFAT and SMB from the system. Progress callbacks arrive every 0.5 ms at
full speed on a 2 GiB file (48196 for W8 in all), so the engine coalesces them before they reach
the main thread. Pause holds a thread for as long as the pause lasts. If the share drops a
connection paused for 60 s, pause on network volumes becomes cancel-and-resume at file
boundaries.

What would change this decision:

- The read/write loop beating `copyfile` by 20% or more on W8 to the image or to the share, in
  two separate passes, would make the engine clone first, then fall back to the loop for data and
  `COPYFILE_METADATA` after. One pass doesn't count: the image runs swing 2× and the two passes
  so far disagree. The share runs are not in yet.
- 8 MiB blocks beating the default by 10% or more on the share would set `COPYFILE_STATE_BSIZE`
  for network volumes. On W8 to the image they were slower in both passes.
- A 60 s pause in the callback failing on SMB moves pause to file boundaries there.
- `COPYFILE_CLONE` not doing a server-side copy within one share, while Finder does, would need
  another path for same-share copies.
