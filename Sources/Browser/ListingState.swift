import Base

/// What a pane has to show for its location.
public enum ListingState: Sendable {
    /// Nothing has arrived yet.
    case loading
    /// The first entries of a large folder, while the rest is still being read.
    case partial(Listing)
    case loaded(Listing)
    /// Privacy protection keeps the app out of the folder until the user grants it Full Disk
    /// Access. A folder whose Unix permissions keep the user out is `failed`: granting the app
    /// access wouldn't help.
    case denied(ListingError)
    case failed(ListingError)

    /// The rows to show, if any have arrived.
    public var listing: Listing? {
        switch self {
        case .partial(let listing), .loaded(let listing): listing
        case .loading, .denied, .failed: nil
        }
    }
}
