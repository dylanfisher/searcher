import AppKit
import Base
import Browser
import Interface
import os

extension UIBench {
    /// Times W2 in column view: `count` ↓ presses in its column, sorted with Folders First
    /// so each ↓ moves onto a folder, faster than the column-open pause, as a held key does, so
    /// each times the selection's frame and only the last folder opens its column; then, once it
    /// has, → and ← alternating `rowCommandPresses` times between W2's column and the last
    /// folder's. W2's folders are empty, so → moves the keys into an empty column. Checks the
    /// cursor, the columns and the focus.
    func pressColumnKeys(_ count: Int) async throws {
        guard count > 0 else { return }
        let pane = try requirePane()
        let window = try requireWindow()
        // Read by W2's column's own load, which lists W2 again.
        pane.settings.foldersFirst = true
        pane.setViewMode(.column)
        guard let trail = pane.columnTrail else { throw Failure("column view has no columns") }
        // The trail starts at the volume's root; W2's column is the focused one.
        let start = trail.focusedIndex
        let first = trail.focused.pane
        try await waitUntilLoaded(first)
        guard let listing = first.state.listing, listing.count > count,
            (0...count).allSatisfy({ listing[$0].type == .directory })
        else {
            throw Failure(
                "\(first.location.folderPath) has fewer than \(count + 1) folders, too few for \(count) "
                    + "↓ presses through folders; pass a folder with at least \(count + 1)")
        }
        guard window.firstResponder === controller?.paneViewController.keyView else {
            throw Failure("W2's column's table doesn't have the keys")
        }
        // The list's cursor carries into the column; start from the first folder instead.
        first.selectFirstRow()
        try await waitUntilSettled(first)
        record.columnDown = try await press(
            Array(repeating: Key.down, count: count), "column key down")
        try expectCursor(atRow: count, in: first, after: "\(count) ↓ presses in column view")
        // The presses come faster than the column-open pause, as a held key's do, so each timed
        // the selection's frame; only the folder they stop on opens its column, after the pause.
        try await waitForColumns(start + 2, in: trail)
        guard trail.columns.count == start + 2,
            trail.columns[start + 1].pane.location
                == first.location.folderChild(named: listing[count].name)
        else {
            throw Failure(
                "↓ onto \(listing[count].name) should open its column alone, but the columns are "
                    + "\(trail.columns.map(\.pane.location.folderPath))")
        }
        for _ in 0..<(Self.rowCommandPresses / 2) {
            record.columnRight += try await press([.right], "column key right")
            guard trail.focusedIndex == start + 1 else {
                throw Failure(
                    "→ left the focus on column \(trail.focusedIndex), not \(start + 1)")
            }
            record.columnLeft += try await press([.left], "column key left")
            guard trail.focusedIndex == start else {
                throw Failure("← left the focus on column \(trail.focusedIndex), not \(start)")
            }
        }
    }

    /// Opens `folder` in column view, sorted with Folders First, and walks it as a held key
    /// does: from its first row, ↓ to the last folder among its first `columnWalkPresses` rows,
    /// faster than the column-open pause, so only that last folder opens its column, after the
    /// pause; then → into that folder once its rows land, ↓ through up to `columnWalkPresses` of
    /// them, and ← back. Each key is timed to its frame (B6); the stalls of the walk are what it
    /// is for (B10).
    func walkColumns(_ folder: String) async throws {
        _ = try await open(folder, "open share")
        try await waitUntilLoaded()
        let pane = try requirePane()
        let window = try requireWindow()
        // Read by the walked column's own load, so folders come before files such as a cover
        // image.
        pane.settings.foldersFirst = true
        pane.setViewMode(.column)
        guard let trail = pane.columnTrail else { throw Failure("column view has no columns") }
        // The trail starts at the share's root; the walked folder's column is the focused one.
        let start = trail.focusedIndex
        let first = trail.focused.pane
        try await waitUntilLoaded(first)
        guard let listing = first.state.listing,
            let lastFolder = (0..<min(Self.columnWalkPresses, listing.count)).last(where: {
                listing[$0].type == .directory
            })
        else {
            throw Failure(
                "none of the first \(Self.columnWalkPresses) rows of \(folder) is a folder, so "
                    + "there is nothing to walk into")
        }
        guard window.firstResponder === controller?.paneViewController.keyView else {
            throw Failure("the walked column's table doesn't have the keys")
        }
        first.selectFirstRow()
        try await waitUntilSettled(first)
        record.columnWalkKey += try await press(
            Array(repeating: Key.down, count: lastFolder), "column walk key")
        try expectCursor(atRow: lastFolder, in: first, after: "\(lastFolder) ↓ presses in the walk")
        try await waitForColumns(start + 2, in: trail)
        guard trail.columns.count == start + 2 else {
            throw Failure(
                "↓ onto \(listing[lastFolder].name) should open its column alone, but the columns "
                    + "are \(trail.columns.map(\.pane.location.folderPath))")
        }
        record.columnWalkKey += try await press([.right], "column walk key")
        guard trail.focusedIndex == start + 1 else {
            throw Failure("→ left the focus on column \(trail.focusedIndex), not \(start + 1)")
        }
        let inner = trail.focused.pane
        try await waitUntilLoaded(inner)
        let innerRows = inner.state.listing?.count ?? 0
        record.columnWalkKey += try await press(
            Array(repeating: Key.down, count: min(Self.columnWalkPresses, innerRows)),
            "column walk key")
        record.columnWalkKey += try await press([.left], "column walk key")
        guard trail.focusedIndex == start else {
            throw Failure("← left the focus on column \(trail.focusedIndex), not \(start)")
        }
    }
}
