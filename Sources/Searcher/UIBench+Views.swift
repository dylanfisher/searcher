import AppKit
import Base
import Browser
import Interface
import os

extension UIBench {
    /// Sorts by the next column through the table's sort descriptors, as a header click does, and
    /// times it to the frame with the re-sorted rows, which the pane sorts off the main thread.
    func changeSort() async throws -> Double {
        try requireVisible()
        let pane = try requirePane()
        let window = try requireWindow()
        guard let table = controller?.paneViewController.keyView as? NSTableView,
            let current = table.sortDescriptors.first?.key,
            let next = table.tableColumns.lazy.compactMap(\.sortDescriptorPrototype)
                .first(where: { $0.key != current })
        else { throw Failure("the list has no other column to sort by") }
        let before = pane.sortColumn
        let start = FrameCommitTimer.now
        let interval = begin("sort change")
        let shown: Result<Double, Failure> = await withCheckedContinuation { continuation in
            whenShown = { [self] pane in
                guard let listing = pane.state.listing, listing.column != before else {
                    return false
                }
                timeFrame(from: start, in: window, "sort change", interval) {
                    continuation.resume(returning: .success($0))
                }
                return true
            }
            table.sortDescriptors = [next]
            if pane.sortColumn == before {
                whenShown = nil
                continuation.resume(
                    returning: .failure(
                        Failure(
                            "changing the table's sort to \(next) left the pane sorted by \(before)"
                        )))
            }
        }
        return try shown.get()
    }

    /// Shows and hides hidden files with Cmd-Shift-., turns Folders First on and off as its menu
    /// item does, and presses the sort keys for Size and Name, on W2, each timed to the frame
    /// with the rows rearranged, which the pane does off the main thread. The settings are in
    /// the bench's own suite, so each launch starts from their defaults and ends there.
    func changeViewSettings() async throws {
        let pane = try requirePane()
        let window = try requireWindow()
        for shown in [true, false] {
            let event = try keyEvent(.commandShiftPeriod, in: window)
            record.hiddenToggle.append(
                try await timeViewChange(
                    "hidden toggle", from: event.timestamp,
                    check: { $0.settings.showHidden == shown }
                ) { window.sendEvent(event) })
        }
        guard
            let foldersFirst = AppCommands.bindings.first(where: {
                $0.command == ViewCommands.toggleFoldersFirst
            })
        else { throw Failure("\(ViewCommands.toggleFoldersFirst.id) isn't registered") }
        for on in [true, false] {
            record.foldersFirstToggle.append(
                try await timeViewChange(
                    "folders first", from: FrameCommitTimer.now,
                    check: { $0.settings.foldersFirst == on }
                ) { foldersFirst.run(CommandContext(pane: pane)) })
        }
        for (key, column) in [(Key.sortBySize, SortColumn.size), (.sortByName, .name)] {
            let event = try keyEvent(key, in: window)
            record.sortKey.append(
                try await timeViewChange(
                    "sort key", from: event.timestamp, check: { $0.sortColumn == column }
                ) { window.sendEvent(event) })
        }
    }

    /// Opens the filter field with Cmd-F, types the first `filterQueryLength` characters of the
    /// middle row's name on W2, then presses Esc, each key timed from its timestamp to the frame
    /// with the rows filtered by the field's new text, which the pane filters off the main
    /// thread. Checks that Cmd-F focused the field and Esc gave the focus back to the list.
    func typeFilter() async throws -> [Double] {
        try requireVisible()
        let pane = try requirePane()
        let window = try requireWindow()
        guard let keyView = controller?.paneViewController.keyView,
            let listing = pane.state.listing, listing.count > 0
        else { throw Failure("\(pane.location.folderPath) has no rows to filter") }
        let query = String(listing[listing.count / 2].name.prefix(Self.filterQueryLength))
        window.sendEvent(try keyEvent(.commandF, in: window))
        guard (window.firstResponder as? NSTextView)?.isFieldEditor == true else {
            throw Failure(
                "Cmd-F left the focus on \(String(describing: window.firstResponder)), not the "
                    + "filter field")
        }
        var samples: [Double] = []
        for length in 1...query.count {
            let typed = String(query.prefix(length))
            let character = typed.suffix(1)
            let event = try keyEvent(
                Key(
                    characters: String(character), keyCode: 0,
                    flags: character.first?.isUppercase == true ? .shift : []), in: window)
            samples.append(
                try await timeViewChange(
                    "filter key", from: event.timestamp, check: { $0.filter.text == typed }
                ) { window.sendEvent(event) })
        }
        let escape = try keyEvent(.escape, in: window)
        samples.append(
            try await timeViewChange(
                "filter key", from: escape.timestamp, check: { $0.filter.isEmpty }
            ) { window.sendEvent(escape) })
        guard window.firstResponder === keyView else {
            throw Failure(
                "Esc in the filter field left the focus on "
                    + "\(String(describing: window.firstResponder)), not the list")
        }
        return samples
    }

    /// Runs `change` and times it from `start` to the frame that shows the pane's rows in its
    /// sort and settings again. Fails at once when `check` says `change` didn't take.
    private func timeViewChange(
        _ name: StaticString, from start: TimeInterval, check: (Pane) -> Bool,
        _ change: () -> Void
    ) async throws -> Double {
        try requireVisible()
        let pane = try requirePane()
        let window = try requireWindow()
        let version = pane.stateVersion
        let interval = begin(name)
        let shown: Result<Double, Failure> = await withCheckedContinuation { continuation in
            whenShown = { [self] pane in
                guard pane.stateVersion != version, pane.state.listing.map(pane.isArranged) == true
                else { return false }
                timeFrame(from: start, in: window, name, interval) {
                    continuation.resume(returning: .success($0))
                }
                return true
            }
            change()
            if !check(pane) {
                whenShown = nil
                continuation.resume(
                    returning: .failure(
                        Failure(
                            "\(name) changed nothing: the pane sorts by \(pane.sortColumn), "
                                + "showHidden \(pane.settings.showHidden), "
                                + "foldersFirst \(pane.settings.foldersFirst)")))
            }
        }
        return try shown.get()
    }
}
