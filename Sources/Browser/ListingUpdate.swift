import Base
import Foundation

/// What a listing load hands the main actor. Each update carries the name of the volume mounted at
/// `/`, read on the load's thread, for the root of the pane's path bar.
public enum ListingUpdate: Sendable {
    /// The folder's entries as `ListingCache` kept them from a listing at `listedAt`, sorted as
    /// asked. Sent before the read starts, and only for a folder on a network volume.
    case cached(Listing, listedAt: Date, rootVolumeName: String)
    /// The first entries read, sorted, while the rest of a large folder is still being read.
    case firstBatch(Listing, rootVolumeName: String)
    /// The load has read no batch for `LoadTimeouts.slow`, counted from the request and from each
    /// batch, so a load waiting on its volume read or behind another read on its share counts
    /// too. It keeps going, and its last update still follows if the read returns. Sent at most
    /// once per load.
    case slow(rootVolumeName: String)
    /// The load has read no batch for `LoadTimeouts.giveUp`, counted as for `slow`. It keeps
    /// going, as after `slow`. Sent at most once per load.
    case gaveUp(rootVolumeName: String)
    /// Every entry in the folder, sorted. The load's last update.
    case full(Listing, rootVolumeName: String)
    /// The folder couldn't be listed. The load's last update.
    case failed(ListingError, rootVolumeName: String)
    /// The folder wasn't found, and the network volume it was on is no longer mounted, so the
    /// folder may still be there. The load's last update.
    case volumeGone(ListingError, rootVolumeName: String)
}
