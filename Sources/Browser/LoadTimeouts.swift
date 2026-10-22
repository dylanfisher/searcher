/// How long a folder load can go before the app says so. The only copy of these numbers.
/// See docs/decisions/0038-slow-volumes.md.
public enum LoadTimeouts {
    /// How long a load runs before its pane shows a spinner, so a folder that lists quickly
    /// never flashes one.
    public static let spinnerDelay: Duration = .milliseconds(150)
    /// How long a load can go without reading a batch before `ListingService` reports it slow and
    /// gives up its slot to other loads.
    public static let slow: Duration = .seconds(3)
    /// How long a load can go without reading a batch before its pane stops waiting and shows the
    /// folder as offline.
    public static let giveUp: Duration = .seconds(30)
}
