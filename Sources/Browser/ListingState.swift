import Base
import Foundation

/// What a pane has to show for its location.
public enum ListingState: Sendable {
    /// Rows a slow or offline pane keeps showing from before its load stalled.
    public struct KeptRows: Sendable {
        public let listing: Listing
        /// When the rows were fully listed; nil for a first batch.
        public let listedAt: Date?
        /// The rows are a full listing read by the pane's own loads. Cached rows and a first
        /// batch aren't: a name they lack may still be there.
        public let isComplete: Bool

        public init(listing: Listing, listedAt: Date?, isComplete: Bool) {
            self.listing = listing
            self.listedAt = listedAt
            self.isComplete = isComplete
        }
    }

    /// Nothing has arrived yet.
    case loading
    /// The first entries of a large folder, while the rest is still being read.
    case partial(Listing)
    case loaded(Listing)
    /// The folder's rows as the listing cache, or `RecentListings` for a folder a pane showed,
    /// kept them from a listing at `listedAt`, shown while the folder is listed again.
    case cachedRefreshing(Listing, listedAt: Date)
    /// The load has read nothing for `LoadTimeouts.slow` and is still waiting, showing the rows
    /// shown before, if any.
    case slow(KeptRows?)
    /// The folder's volume stopped answering, returned nothing for `LoadTimeouts.giveUp`, or is
    /// no longer mounted. The pane shows the rows shown before, if any.
    case offline(KeptRows?)
    /// Privacy protection keeps the app out of the folder until the user grants it Full Disk
    /// Access. A folder whose Unix permissions keep the user out is `failed`: granting the app
    /// access wouldn't help.
    case denied(ListingError)
    case failed(ListingError)
    /// The pane is at a server with no share in the mount table, so it has no rows. It lists
    /// again when a read of the table holds one of its shares
    /// (docs/decisions/0114-server-location.md).
    case notConnected
    /// A server's rows, its mounted shares and those it listed that aren't mounted, with why
    /// they may not be all it offers. Shown as `loaded` rows are, but not a complete listing: a
    /// share the server didn't list may be there (docs/decisions/0115-server-shares.md).
    case serverListed(Listing, ServerNotice)

    /// The rows to show, if any have arrived.
    public var listing: Listing? {
        switch self {
        case .partial(let listing), .loaded(let listing), .cachedRefreshing(let listing, _),
            .serverListed(let listing, _):
            listing
        case .slow(let kept), .offline(let kept): kept?.listing
        case .loading, .denied, .failed, .notConnected: nil
        }
    }

    /// When the rows of a cached, slow or offline state were fully listed; nil for every other
    /// state, and for kept rows that are a first batch.
    public var listedAt: Date? {
        switch self {
        case .cachedRefreshing(_, let listedAt): listedAt
        case .slow(let kept), .offline(let kept): kept?.listedAt
        case .loading, .partial, .loaded, .denied, .failed, .notConnected, .serverListed: nil
        }
    }

    /// The path of a folder that isn't there, for the missing state: it was deleted or moved, a
    /// file has its name now, or it is on a volume that isn't mounted. The pane stays at that path
    /// and shows it rather than moving to a folder that is there, so a restored pane keeps its
    /// place until the folder comes back. Nil for every other state.
    public var missingFolder: String? {
        guard case .failed(let error) = self else { return nil }
        switch error.reason {
        case .notFound, .notADirectory: return error.path
        case .privacyProtected, .permissionDenied, .unreachable, .other: return nil
        }
    }

    /// The rows shown are a full listing read by the pane's own loads, so a name they lack isn't
    /// in the folder.
    public var showsCompleteListing: Bool {
        switch self {
        case .loaded: true
        case .slow(let kept), .offline(let kept): kept?.isComplete ?? false
        case .loading, .partial, .cachedRefreshing, .denied, .failed, .notConnected,
            .serverListed:
            false
        }
    }

    /// The rows are the whole folder in its sort, so their first row is the folder's: a full
    /// listing or cached rows, kept or not, but not a first batch.
    var showsWholeFolder: Bool {
        switch self {
        case .loaded, .cachedRefreshing, .serverListed: true
        case .slow(let kept), .offline(let kept):
            kept.map { $0.isComplete || $0.listedAt != nil } ?? false
        case .loading, .partial, .denied, .failed, .notConnected: false
        }
    }

    /// The rows shown came from the pane's own load, a first batch or all of it, so the folder's
    /// volume answered. Cached rows, and the rows a slow or offline state keeps, come from a
    /// volume that hasn't answered since, and a read there can wait on a share that is gone.
    public var isAnswered: Bool {
        switch self {
        case .partial, .loaded, .serverListed: true
        case .loading, .cachedRefreshing, .slow, .offline, .denied, .failed, .notConnected: false
        }
    }

    /// The same state showing `listing`, a re-sort or re-filter of the rows it shows.
    func showing(_ listing: Listing) -> ListingState {
        switch self {
        case .partial: .partial(listing)
        case .loaded: .loaded(listing)
        case .cachedRefreshing(_, let listedAt): .cachedRefreshing(listing, listedAt: listedAt)
        case .serverListed(_, let notice): .serverListed(listing, notice)
        case .slow(let kept?): .slow(kept.showing(listing))
        case .offline(let kept?): .offline(kept.showing(listing))
        case .loading, .slow(nil), .offline(nil), .denied, .failed, .notConnected:
            preconditionFailure("\(self) has no rows to replace")
        }
    }
}

extension ListingState.KeptRows {
    fileprivate func showing(_ listing: Listing) -> Self {
        Self(listing: listing, listedAt: listedAt, isComplete: isComplete)
    }
}
