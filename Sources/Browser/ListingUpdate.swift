import Base

/// What a listing load hands the main actor. Each update carries the name of the volume mounted at
/// `/`, read on the load's thread, for the root of the pane's path bar.
public enum ListingUpdate: Sendable {
    /// The first entries read, sorted, while the rest of a large folder is still being read.
    case firstBatch(Listing, rootVolumeName: String)
    /// The load has read no batch for `LoadTimeouts.slow`. It keeps reading, and `full` or
    /// `failed` still follows if the read returns. Sent at most once per load.
    case slow(rootVolumeName: String)
    /// Every entry in the folder, sorted. The load's last update.
    case full(Listing, rootVolumeName: String)
    /// The folder couldn't be listed. The load's last update.
    case failed(ListingError, rootVolumeName: String)
}
