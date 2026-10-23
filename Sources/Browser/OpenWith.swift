import Foundation
import UniformTypeIdentifiers

/// The apps Open With lists for a selection: those that open every selected type, the default app
/// first and the rest by name, one per bundle ID. Each type's apps are listed once, off the main
/// thread, and kept for the life of the cache, so a menu opened again fills from it
/// (docs/decisions/0073-open-with.md).
@MainActor
public final class OpenWith {
    public struct App: Hashable, Sendable {
        public let url: URL
        /// Identifies the app across copies of it: its bundle ID, or its path when it has none.
        public let bundleID: String
        /// The name Finder shows for the app.
        public let name: String

        /// Reads the app's bundle and name from the disk, so it runs off the main thread.
        nonisolated init(at url: URL) {
            self.url = url
            bundleID = Bundle(url: url)?.bundleIdentifier ?? url.path
            // The display name keeps ".app" when Finder shows every extension; its Open With
            // menu leaves it off either way.
            let name = FileManager.default.displayName(atPath: url.path)
            self.name = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
    }

    public struct Choices: Equatable, Sendable {
        /// The app that opens every selected type by default; nil when their default apps differ.
        public let defaultApp: App?
        /// The other apps that open every selected type, by name.
        public let others: [App]

        public var all: [App] { (defaultApp.map { [$0] } ?? []) + others }
    }

    /// One type's apps in Launch Services' order, its default app first, one per bundle ID.
    struct AppList: Sendable {
        let apps: [App]
        let defaultBundleID: String?
    }

    private let systemActions: any SystemActions
    private let didBuild: @Sendable (UTType, Duration) -> Void
    private var lists: [UTType: AppList] = [:]
    /// Each type's build, started once and kept, so callers waiting on one type share it.
    private var builds: [UTType: Task<AppList, Never>] = [:]
    /// Where lists are built. Tests suspend a queue of their own here to hold a build.
    var buildQueue = DispatchQueue.global(qos: .userInitiated)

    /// `didBuild` gets each type and how long its first build took, off the main thread.
    public init(
        systemActions: any SystemActions,
        didBuild: @escaping @Sendable (UTType, Duration) -> Void
    ) {
        self.systemActions = systemActions
        self.didBuild = didBuild
    }

    /// The choices for `types` from the cache, or nil while any type's list isn't built.
    public func cachedChoices(for types: Set<UTType>) -> Choices? {
        var found: [AppList] = []
        for type in types {
            guard let list = lists[type] else { return nil }
            found.append(list)
        }
        return Self.choices(from: found)
    }

    /// The choices for `types`, building the lists the cache lacks.
    public func choices(for types: Set<UTType>) async -> Choices {
        var found: [AppList] = []
        for task in types.map(build) {
            found.append(await task.value)
        }
        return Self.choices(from: found)
    }

    /// The types of the entries selected in `pane`, from their kinds, so finding them reads no
    /// file. Empty when nothing is selected.
    public static func types(in pane: Pane) -> Set<UTType> {
        guard let listing = pane.state.listing else { return [] }
        return Set(pane.selectedRows.map { listing.kind(atRow: $0).type })
    }

    /// Opens the entries selected in `pane` in the app at `application`.
    public static func open(selectionOf pane: Pane, withApplicationAt application: URL) {
        pane.systemActions.open(
            ClipboardCommands.selectedURLs(in: pane), withApplicationAt: application)
    }

    private func build(_ type: UTType) -> Task<AppList, Never> {
        if let task = builds[type] { return task }
        let systemActions = systemActions
        let didBuild = didBuild
        let queue = buildQueue
        let task = Task {
            let list = await withCheckedContinuation { continuation in
                queue.async {
                    let start = ContinuousClock.now
                    let list = Self.list(for: type, from: systemActions)
                    didBuild(type, .now - start)
                    continuation.resume(returning: list)
                }
            }
            lists[type] = list
            return list
        }
        builds[type] = task
        return task
    }

    private nonisolated static func list(for type: UTType, from systemActions: any SystemActions)
        -> AppList
    {
        let defaultURL = systemActions.defaultApplicationURL(toOpen: type)
        // The default app's copy goes first, so it is the one kept when the Mac has two.
        let urls = (defaultURL.map { [$0] } ?? []) + systemActions.applicationURLs(toOpen: type)
        var seen: Set<String> = []
        var apps: [App] = []
        for url in urls {
            let app = App(at: url)
            if seen.insert(app.bundleID).inserted {
                apps.append(app)
            }
        }
        return AppList(apps: apps, defaultBundleID: defaultURL == nil ? nil : apps.first?.bundleID)
    }

    /// The apps in every list, the default app first when every list has the same one.
    private static func choices(from lists: [AppList]) -> Choices {
        guard let first = lists.first else { return Choices(defaultApp: nil, others: []) }
        var common = Set(first.apps.map(\.bundleID))
        for list in lists.dropFirst() {
            common.formIntersection(list.apps.map(\.bundleID))
        }
        let defaults = Set(lists.map(\.defaultBundleID))
        let defaultID = defaults.count == 1 ? defaults.first.flatMap { $0 } : nil
        let apps = first.apps.filter { common.contains($0.bundleID) }
        let defaultApp = defaultID.flatMap { id in apps.first { $0.bundleID == id } }
        let others = apps.filter { $0.bundleID != defaultApp?.bundleID }.sorted { a, b in
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.bundleID < b.bundleID
            }
        }
        return Choices(defaultApp: defaultApp, others: others)
    }
}
