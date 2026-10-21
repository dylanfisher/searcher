import Base

/// What a listing load hands the main actor.
public enum ListingUpdate: Sendable {
    /// The first entries read, sorted, while the rest of a large folder is still being read.
    case firstBatch(Listing)
    /// Every entry in the folder, sorted. The load's last update.
    case full(Listing)
    /// The folder couldn't be listed. The load's last update.
    case failed(ListingError)
}
