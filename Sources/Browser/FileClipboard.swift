import Foundation

/// A pasteboard that carries files: the general pasteboard for cut, copy and paste, or a drag's.
/// Interface implements it over `NSPasteboard`; Browser sees only URLs and a change count.
@MainActor
public protocol FileClipboard: AnyObject {
    /// Goes up with every write to the clipboard, by Searcher or by any other app.
    var changeCount: Int { get }
    /// Replaces what the clipboard holds with `urls`, which are file URLs.
    func write(_ urls: [URL])
    /// The file URLs the clipboard holds, in order; empty when it holds none.
    func fileURLs() -> [URL]
}
