# 0005. FSEvents for local volumes, per-folder vnode watches for network volumes

- **Date:** 2026-10-20
- **Status:** accepted

## Context

Panes must show changes without the user refreshing, and many panes and tabs are restored at
launch. Dylan's main use case includes an SMB share changed by other machines. Spike S3 measured
FSEvents and per-folder `DispatchSource` watches locally, on SMB from this Mac, and on SMB with
changes made on the NAS (spike S3).

## Decision

Folders on local volumes are watched with FSEvents using file-level events, so a pane patches the
rows that changed. Folders on network volumes are watched with one vnode `DispatchSource` each,
and the pane re-lists the folder on every event. Every pane also re-lists when it regains focus.

## Alternatives considered

- **FSEvents everywhere** — rejected: FSEvents alone received no events for changes made by
  other machines on SMB, with one stream, many streams, or a parent stream.
- **vnode everywhere** — rejected: it only says "this folder changed", so a 100k-entry local
  folder would be re-listed on every burst, and each watch holds a file descriptor.
- **Polling network folders** — kept only as refresh-on-focus; change notifications arrived in
  about 1 s on Synology, and a timed poll adds round trips on every share.

## Consequences

The watch layer has two implementations behind one interface, chosen by volume type. Network
panes cost one file descriptor each. A server without change notifications only updates on focus
or manual refresh.
