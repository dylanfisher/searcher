import Base

/// What a pane has to show for its location.
public enum ListingState: Sendable {
    /// Nothing has arrived yet.
    case loading
    /// The first entries of a large folder, while the rest is still being read.
    case partial(Listing)
    case loaded(Listing)
    /// The system refused to list the folder: a privacy-protected folder the app has no access to,
    /// or a permissions mismatch.
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
