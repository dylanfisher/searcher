import Base
import Foundation

/// The app's file clipboard and what the last Cut put on it: the cut paths and the clipboard's
/// change count right after the write. Any later write, by Searcher or another app, changes the
/// count and ends the cut, so Paste then copies (docs/decisions/0069-cut-and-paste.md). One for
/// the app, so a cut in one window pastes as a move in another, and every list dims the same
/// rows.
@MainActor
public final class CutState {
    public let clipboard: any FileClipboard
    private var cut: (paths: [String], changeCount: Int)?
    private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor () -> Void
    }

    public init(clipboard: any FileClipboard) {
        self.clipboard = clipboard
    }

    /// Puts `urls` on the clipboard for a copy, ending any cut.
    func copy(_ urls: [URL]) {
        clipboard.write(urls)
        set(nil)
    }

    /// Puts `urls` on the clipboard and marks them cut.
    func cut(_ urls: [URL]) {
        clipboard.write(urls)
        set((urls.map(\.path), clipboard.changeCount))
    }

    /// The cut paths while the clipboard still holds what the cut wrote; nil otherwise.
    var cutPaths: [String]? {
        guard let cut, cut.changeCount == clipboard.changeCount else { return nil }
        return cut.paths
    }

    /// Ends the cut, as a paste that moved its files does.
    func clear() {
        set(nil)
    }

    /// The names of the cut entries in `folder`, while the cut lasts; empty otherwise. Paths
    /// compare exactly, as the pane's names do. A server's entries are its shares' mount points
    /// in `/Volumes` (`MountTable.mountPoint(ofRow:in:)`), so a cut of one, made in a pane at
    /// `/Volumes`, dims its row there too.
    public func cutNames(in folder: Location) -> Set<String> {
        guard let paths = cutPaths else { return [] }
        let parent =
            switch folder {
            case .folder(let path): path
            case .server: Server.sharesFolder.folderPath
            }
        return Set(
            paths.lazy.filter { parentPath(of: $0) == parent }
                .map { lastComponent(of: $0) })
    }

    /// Ends a cut whose clipboard has been written since, and tells the observers. The app calls
    /// it when it becomes active: another app's write, such as Finder's Copy, most often happens
    /// while the user is in that app.
    public func clipboardMayHaveChanged() {
        guard cut != nil, cutPaths == nil else { return }
        set(nil)
    }

    /// Runs `handler` after each change of the cut, for as long as `owner` exists.
    public func observe(for owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    /// How many observers are kept, those whose owner is gone among them. Tests read it.
    var observerCount: Int { observers.count }

    private func set(_ cut: (paths: [String], changeCount: Int)?) {
        let changed = self.cut != nil || cut != nil
        self.cut = cut
        guard changed else { return }
        observers.removeAll { $0.owner == nil }
        for observer in observers {
            observer.handler()
        }
    }
}
