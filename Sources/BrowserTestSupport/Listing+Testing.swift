import Browser

/// The names of `listing`'s rows, in row order.
public func names(_ listing: Listing) -> [String] {
    (0..<listing.count).map { listing[$0].name }
}
