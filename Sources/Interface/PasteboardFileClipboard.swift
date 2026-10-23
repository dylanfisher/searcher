import AppKit
import Browser

/// A `FileClipboard` over an `NSPasteboard`, in the shape Finder writes and reads: one item per
/// file holding its `public.file-url`, and the names, one per line, as text on the first item, so
/// a text field pastes the names. Reading takes every file URL and ignores the rest, such as web
/// URLs and text. The app passes the general pasteboard; tests pass one of their own.
/// A drag's pasteboard takes the same shape.
@MainActor
public final class PasteboardFileClipboard: FileClipboard {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func write(_ urls: [URL]) {
        let items = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        items.first?.setString(
            urls.map(\.lastPathComponent).joined(separator: "\n"), forType: .string)
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else {
            preconditionFailure("the pasteboard refused \(urls.count) file URLs")
        }
    }

    /// Reads through `NSURL`, so the file names older apps write as `NSFilenamesPboardType`
    /// read as file URLs too.
    public func fileURLs() -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects ?? []).compactMap { $0 as? URL }
    }
}
