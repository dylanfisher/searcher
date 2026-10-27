import AppKit
import Base
import Browser

extension ListingViewController {
    /// The thumbnail the service keeps for `row`'s file, as it is in `listing`; nil when it keeps
    /// none, the file has none, or may not show one.
    func keptThumbnail(row: Int, in listing: Listing) -> CGImage? {
        let entry = listing[row]
        guard let thumbnails = pane.service.thumbnails,
            ThumbnailService.shows(entry, kind: listing.kind(atRow: row)),
            case .some(.some(let image)) = thumbnails.cached(
                at: pane.location.folderChild(named: entry.name).folderPath, entry: entry,
                side: ListingCellLayout.iconSize)
        else { return nil }
        return image
    }

    @objc func rowsOnScreenMayHaveChanged(_ notification: Notification) {
        updateThumbnails()
    }

    /// Asks for the thumbnail of each row on screen that may show one and has none kept or
    /// asked for, and cancels the requests of rows that left the screen, or whose entry or
    /// folder changed. A request cancelled while it waits for its volume's slot is never made;
    /// one being made is kept by the service, and shows when its row is next filled. Rows its
    /// volume hasn't answered with, as cached rows, ask for none, and neither does a folder
    /// whose volume isn't known yet or is a share.
    func updateThumbnails() {
        guard let thumbnails = pane.service.thumbnails, isViewLoaded else { return }
        var onScreen: Set<String> = []
        if let listing, pane.state.isAnswered, let volume = pane.folderVolume,
            ThumbnailService.makes(on: volume)
        {
            let rows = tableView.rows(in: tableView.visibleRect)
            for row in rows.lowerBound..<min(rows.upperBound, listing.count) {
                let entry = listing[row]
                guard ThumbnailService.shows(entry, kind: listing.kind(atRow: row)) else {
                    continue
                }
                let path = pane.location.folderChild(named: entry.name).folderPath
                if let request = thumbnailRequests[entry.name], request.path == path,
                    request.entry == entry
                {
                    onScreen.insert(entry.name)
                    continue
                }
                if thumbnails.cached(at: path, entry: entry, side: ListingCellLayout.iconSize)
                    != nil
                {
                    continue
                }
                onScreen.insert(entry.name)
                thumbnailRequests[entry.name]?.task.cancel()
                thumbnailRequests[entry.name] = ThumbnailRequest(
                    path: path, entry: entry,
                    task: requestThumbnail(
                        at: path, entry: entry, on: volume, from: thumbnails))
            }
        }
        for (name, request) in thumbnailRequests where !onScreen.contains(name) {
            request.task.cancel()
            thumbnailRequests[name] = nil
        }
    }

    /// Asks `thumbnails` for the thumbnail of `entry`, the file at `path`, and shows it in the
    /// entry's row once made, unless the request was cancelled first.
    private func requestThumbnail(
        at path: String, entry: DirectoryEntry, on volume: VolumeIdentity,
        from thumbnails: ThumbnailService
    ) -> Task<Void, Never> {
        Task { [weak self] in
            let thumbnail: CGImage?
            do {
                thumbnail = try await thumbnails.thumbnail(
                    at: path, entry: entry, side: ListingCellLayout.iconSize, on: volume)
            } catch {
                // Cancelled while it waited: the row left the screen.
                return
            }
            guard let self, !Task.isCancelled else { return }
            thumbnailRequests[entry.name] = nil
            guard let thumbnail, let listing, let row = listing.row(named: entry.name),
                listing[row] == entry,
                let cell = tableView.view(
                    atColumn: tableView.column(withIdentifier: SortColumn.name.identifier),
                    row: row, makeIfNecessary: false) as? NSTableCellView
            else { return }
            cell.imageView?.image = NSImage(thumbnail: thumbnail)
        }
    }
}
