import Base
import Foundation

/// What a listing load hands the main actor. Each update carries the name of the volume mounted at
/// `/`, read on the load's thread, for the root of the pane's path bar. The updates that can take
/// a pane slow or offline also carry `volumeName`, the name of the volume holding the folder,
/// for the note that says so: the last component of the longest mount point holding it in the
/// mount table, or the root volume's name when that is `/`.
public enum ListingUpdate: Sendable {
    /// The folder's entries as `ListingCache` kept them from a listing at `listedAt`, sorted as
    /// asked. Sent before the read starts, and only for a folder on a network volume, or for a
    /// server whose share list `ServerShares` keeps.
    case cached(Listing, listedAt: Date, rootVolumeName: String)
    /// The first entries read, sorted, while the rest of a large folder is still being read.
    case firstBatch(Listing, rootVolumeName: String)
    /// The load has read no batch for `LoadTimeouts.slow`, counted from the request and from each
    /// batch, so a load waiting on its volume read or behind another read on its share counts
    /// too. It keeps going, and its last update still follows if the read returns. Sent at most
    /// once per load.
    case slow(rootVolumeName: String, volumeName: String)
    /// The load has read no batch for `LoadTimeouts.giveUp`, counted as for `slow`. It keeps
    /// going, as after `slow`. Sent at most once per load.
    case gaveUp(rootVolumeName: String, volumeName: String)
    /// Every entry in the folder, sorted. The load's last update. A server's rows, its mounted
    /// shares and those it listed that aren't mounted, with nothing to say about them.
    case full(Listing, rootVolumeName: String)
    /// The folder couldn't be listed. The load's last update.
    case failed(ListingError, rootVolumeName: String, volumeName: String)
    /// The folder wasn't found, and the network volume it was on is no longer mounted, so the
    /// folder may still be there. `volumeName` names that volume by where it was mounted. The
    /// load's last update.
    case volumeGone(ListingError, rootVolumeName: String, volumeName: String)
    /// The server has no share in the mount table: all of them were ejected or unmounted, or a
    /// restored pane's server hasn't mounted one yet. The load's last update
    /// (docs/decisions/0114-server-location.md).
    case notConnected(rootVolumeName: String)
    /// A server's rows, said with `notice`: why they may not be every share it offers. The
    /// load's last update; a server whose rows need no notice gets `full`
    /// (docs/decisions/0115-server-shares.md).
    case serverListed(Listing, ServerNotice, rootVolumeName: String)
}
