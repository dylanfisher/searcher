import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// The apps Open With lists for a selection: those that open every selected type, the default app
/// first and the rest by name, one per bundle ID and version. Each type's apps are listed and read
/// once, off the main thread, and kept for the life of the cache, so a menu opened again fills
/// from it. Each app's icon is asked for once; a type's list waits up to `iconWait` for its icons,
/// and an icon that lands later shows the next time the menu opens
/// (docs/decisions/0073-open-with.md).
@MainActor
public final class OpenWith {
    public struct App: Hashable, Sendable {
        public let url: URL
        /// Identifies the app across copies of it, with `version`: its bundle ID, or its path
        /// when it has none.
        public let bundleID: String
        /// The name Finder shows for the app, which ends in ".app" when Finder shows every
        /// extension.
        public let name: String
        /// The app's short version, which tells apart two apps with one name.
        public let version: String?
        /// The app's icon at 16 points, 2x; nil until it lands, or when it couldn't be made.
        public internal(set) var icon: CGImage?

        public init(url: URL, bundleID: String, name: String, version: String?) {
            self.url = url
            self.bundleID = bundleID
            self.name = name
            self.version = version
        }

        /// The app at `url`, its bundle ID, version and display name read from the disk, so it
        /// runs off the main thread. An app with no readable bundle is listed by its path, with
        /// no version, and `missingBundle` is told.
        public nonisolated init(readingBundleAt url: URL, missingBundle: (URL) -> Void) {
            let bundle = Bundle(url: url)
            if bundle == nil {
                missingBundle(url)
            }
            self.init(
                url: url, bundleID: bundle?.bundleIdentifier ?? url.path,
                name: FileManager.default.displayName(atPath: url.path),
                version: bundle?.infoDictionary?["CFBundleShortVersionString"] as? String)
        }

        /// Copies of one version of an app share it; Open With lists one of them.
        fileprivate var key: [String] { [bundleID, version ?? ""] }
    }

    public struct Choices: Equatable, Sendable {
        /// The app that opens every selected type by default; nil when their default apps differ.
        public let defaultApp: App?
        /// The other apps that open every selected type, by name, then version.
        public let others: [App]

        public var all: [App] { (defaultApp.map { [$0] } ?? []) + others }

        /// Whether `app`'s item shows its version: another app listed has its name.
        public func showsVersion(of app: App) -> Bool {
            app.version != nil && all.contains { $0.name == app.name && $0.key != app.key }
        }
    }

    /// One type's apps in Launch Services' order, its default app first, one per bundle ID and
    /// version.
    struct AppList: Sendable {
        let apps: [App]
        let defaultKey: [String]?
    }

    private let systemActions: any SystemActions
    private let didBuild: @Sendable (UTType, Duration) -> Void
    private var lists: [UTType: AppList] = [:]
    /// Each type's build, started once and kept, so callers waiting on one type share it.
    private var builds: [UTType: Task<AppList, Never>] = [:]
    /// The icons that landed, by app URL; an app whose icon couldn't be made has none.
    private var icons: [URL: CGImage] = [:]
    /// The apps whose icons were asked for, and those whose answer landed.
    private var iconsAsked: Set<URL> = []
    private var iconsLanded: Set<URL> = []
    /// Builds waiting for their apps' icons, by ID.
    private var iconWaiters: [UUID: IconWaiter] = [:]
    /// Where Launch Services is asked for a type's apps and the apps are read. Tests suspend a
    /// queue of their own here to hold a build.
    var buildQueue = DispatchQueue.global(qos: .userInitiated)
    /// How long a type's list waits for its apps' icons before it is shown without the rest.
    var iconWait = Duration.seconds(1)

    private struct IconWaiter {
        let urls: [URL]
        let continuation: CheckedContinuation<Void, Never>
    }

    /// `didBuild` gets each type and how long listing and reading its apps took, off the main
    /// thread.
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
        return choices(from: found)
    }

    /// The choices for `types`, building the lists the cache lacks.
    public func choices(for types: Set<UTType>) async -> Choices {
        var found: [AppList] = []
        for task in types.map(build) {
            found.append(await task.value)
        }
        return choices(from: found)
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

    /// Opens the App Store's search for the file extensions of the types selected in `pane`, as
    /// Finder's App Store… item does.
    public static func searchAppStore(forSelectionOf pane: Pane) {
        let terms = types(in: pane).map { type in
            type.preferredFilenameExtension ?? type.localizedDescription ?? type.identifier
        }
        var search = URLComponents()
        search.scheme = "macappstore"
        search.host = ""
        search.queryItems = [
            URLQueryItem(name: "action", value: "search"),
            URLQueryItem(name: "term", value: terms.sorted().joined(separator: " ")),
        ]
        guard let url = search.url else {
            preconditionFailure("no App Store URL for \(search)")
        }
        pane.systemActions.openURL(url)
    }

    private func build(_ type: UTType) -> Task<AppList, Never> {
        if let task = builds[type] { return task }
        let systemActions = systemActions
        let didBuild = didBuild
        let queue = buildQueue
        let task = Task {
            let list = await Self.list(
                for: type, from: systemActions, on: queue, didBuild: didBuild)
            await waitForIcons(of: list.apps.map(\.url))
            lists[type] = list
            return list
        }
        builds[type] = task
        return task
    }

    /// Asks for the icons of `urls` not yet asked for, and returns when every one has landed or
    /// `iconWait` has passed, so an icon that never comes holds the list back no longer than
    /// that.
    private func waitForIcons(of urls: [URL]) async {
        let systemActions = systemActions
        for url in urls where iconsAsked.insert(url).inserted {
            Task {
                let icon = await systemActions.applicationIcon(at: url)
                iconLanded(icon, for: url)
            }
        }
        guard !urls.allSatisfy(iconsLanded.contains) else { return }
        let id = UUID()
        let wait = iconWait
        await withCheckedContinuation { continuation in
            iconWaiters[id] = IconWaiter(urls: urls, continuation: continuation)
            Task {
                try? await Task.sleep(for: wait)
                stopWaiting(id)
            }
        }
    }

    private func iconLanded(_ icon: CGImage?, for url: URL) {
        iconsLanded.insert(url)
        icons[url] = icon
        for (id, waiter) in iconWaiters where waiter.urls.allSatisfy(iconsLanded.contains) {
            stopWaiting(id)
        }
    }

    private func stopWaiting(_ id: UUID) {
        iconWaiters.removeValue(forKey: id)?.continuation.resume()
    }

    /// Asks Launch Services for `type`'s apps and reads each app, on `queue`, off the main
    /// thread.
    private nonisolated static func list(
        for type: UTType, from systemActions: any SystemActions, on queue: DispatchQueue,
        didBuild: @escaping @Sendable (UTType, Duration) -> Void
    ) async -> AppList {
        await withCheckedContinuation { continuation in
            queue.async {
                let start = ContinuousClock.now
                let defaultURL = systemActions.defaultApplicationURL(toOpen: type)
                // The default app's copy goes first, so it is the one kept when the Mac has two.
                let urls =
                    (defaultURL.map { [$0] } ?? []) + systemActions.applicationURLs(toOpen: type)
                var paths: Set<String> = []
                var keys: Set<[String]> = []
                let apps =
                    urls
                    .filter { paths.insert($0.standardizedFileURL.path).inserted }
                    .map { systemActions.application(at: $0) }
                    .filter { keys.insert($0.key).inserted }
                didBuild(type, .now - start)
                continuation.resume(
                    returning: AppList(
                        apps: apps, defaultKey: defaultURL == nil ? nil : apps.first?.key))
            }
        }
    }

    /// The apps in every list with the icons that landed, the default app first when every list
    /// has the same one.
    private func choices(from lists: [AppList]) -> Choices {
        guard let first = lists.first else { return Choices(defaultApp: nil, others: []) }
        var common = Set(first.apps.map(\.key))
        for list in lists.dropFirst() {
            common.formIntersection(list.apps.map(\.key))
        }
        let defaults = Set(lists.map(\.defaultKey))
        let defaultKey = defaults.count == 1 ? defaults.first.flatMap { $0 } : nil
        let apps = first.apps.filter { common.contains($0.key) }.map { app in
            var app = app
            app.icon = icons[app.url]
            return app
        }
        let defaultApp = defaultKey.flatMap { key in apps.first { $0.key == key } }
        let others = apps.filter { $0.key != defaultApp?.key }.sorted { a, b in
            for (x, y) in [(a.name, b.name), (a.version ?? "", b.version ?? "")] {
                switch x.localizedStandardCompare(y) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return a.url.path < b.url.path
        }
        return Choices(defaultApp: defaultApp, others: others)
    }
}
