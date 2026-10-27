import Base
import Browser

extension BenchCase {
    /// One FSEvents batch from a churning build folder under a shown folder, turned into the
    /// folder's change: 1,000 file events two levels below it and one must-rescan event for the
    /// build folder's own subfolder, which can't change what the shown folder lists. Times
    /// `FolderMonitor.change`, which must find nothing to do without reading the disk. The events
    /// are made once, untimed. Reported only; a `--path` folder doesn't apply.
    static let folderEvents: [BenchCase] = [
        BenchCase(
            name: "FSEvents batch: 1k deep events and a deep rescan", budget: nil,
            unit: .milliseconds
        ) { _ in timeFolderEvents() }
    ]

    /// A shown folder no bench creates: the batch names nothing in it to read.
    static let folderEventsFolder = "/searcher-bench/shown"
    static let folderEventsBatch: [FileEvent] =
        (0..<1_000).map {
            FileEvent(
                path: folderEventsFolder + "/build/obj/\($0 % 40)/file-\($0).o",
                flags: [.created, .modified])
        } + [FileEvent(path: folderEventsFolder + "/build/obj", flags: .mustRescan)]

    private static func timeFolderEvents() -> Double {
        let events = folderEventsBatch
        let start = ContinuousClock.now
        let change = FolderMonitor.change(for: events, in: folderEventsFolder)
        let elapsed = milliseconds(.now - start)
        guard change == nil else {
            preconditionFailure(
                "a batch under \(folderEventsFolder)/build made \(String(describing: change))")
        }
        return elapsed
    }
}
