import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// The apps Open With lists for a selection: those that open every selected type, the default app
/// first and the rest by name, one per bundle ID and version. Each type's apps are listed and read
/// off the main thread and cached, so a menu opened again fills from it; `refresh` lists them
/// again in the background, so an app installed since shows the next time. Each app's icon is
/// asked for once per path and version; a type's list waits up to `iconWait` for its icons, and
/// an icon that lands later shows the next time the menu opens
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
        /// An app keeps its icon while its path and version stay the same.
        fileprivate var iconKey: [String] { [url.path, version ?? ""] }
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
    /// Each type's latest build or refresh, kept so callers waiting on one type share it.
    private var builds: [UTType: Task<AppList, Never>] = [:]
    /// The types whose build or refresh is running.
    private var building: Set<UTType> = []
    /// The types whose list landed less than `refreshInterval` ago, which `refresh` skips.
    private(set) var resting: Set<UTType> = []
    /// The icons that landed, by app path and version; an app whose icon couldn't be made has
    /// none.
    private var icons: [[String]: CGImage] = [:]
    /// The apps whose icons were asked for, and those whose answer landed, by path and version.
    private var iconsAsked: Set<[String]> = []
    private var iconsLanded: Set<[String]> = []
    /// Builds waiting for their apps' icons, by ID.
    private var iconWaiters: [UUID: IconWaiter] = [:]
    /// Where Launch Services is asked for a type's apps and the apps are read. Tests suspend a
    /// queue of their own here to hold a build.
    var buildQueue = DispatchQueue.global(qos: .userInitiated)
    /// How long a type's list waits for its apps' icons before it is shown without the rest.
    var iconWait = Duration.seconds(1)
    /// How long a type's list stays after it lands before `refresh` lists the type again, so
    /// opening the menu over and over asks Launch Services at most this often.
    var refreshInterval = Duration.seconds(5)
    /// Where a list waits out `iconWait` and `refreshInterval`. Tests pass a clock they advance.
    var clock: any Clock<Duration> = ContinuousClock()

    private struct IconWaiter {
        let keys: [[String]]
        let continuation: CheckedContinuation<Void, Never>
        /// Ends the wait after `iconWait`; cancelled when the icons land first.
        let timer: Task<Void, Never>
    }

    /// `didBuild` gets each type and how long listing and reading its apps took, off the main
    /// thread, for each build and refresh.
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

    /// Lists again, in the background, each of `types` that has a list, none running, and none
    /// landed in the last `refreshInterval`. The cache keeps the old list until the new one
    /// lands and replaces it.
    public func refresh(_ types: Set<UTType>) {
        for type in types
        where lists[type] != nil && !building.contains(type) && !resting.contains(type) {
            _ = startBuild(type)
        }
    }

    /// The types of the entries selected in `pane`, from their kinds, so finding them reads no
    /// file. Empty when nothing is selected, and when a selected row has no location
    /// (`Pane.selectsUnmountedShare`), which turns Open With off.
    public static func types(in pane: Pane) -> Set<UTType> {
        guard let listing = pane.state.listing, !pane.selectsUnmountedShare else { return [] }
        return Set(pane.selectedRows.map { listing.kind(atRow: $0).type })
    }

    /// Opens the entries selected in `pane` in the app at `application`.
    public static func open(selectionOf pane: Pane, withApplicationAt application: URL) {
        guard let urls = ClipboardCommands.selectedURLs(in: pane) else { return }
        pane.systemActions.open(urls, withApplicationAt: application)
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
        return startBuild(type)
    }

    /// Lists `type`'s apps, puts the list in the cache when it lands, and keeps the type
    /// `resting` for `refreshInterval` after.
    private func startBuild(_ type: UTType) -> Task<AppList, Never> {
        let systemActions = systemActions
        let didBuild = didBuild
        let queue = buildQueue
        building.insert(type)
        let task = Task {
            let list = await Self.list(
                for: type, from: systemActions, on: queue, didBuild: didBuild)
            await waitForIcons(of: list.apps)
            lists[type] = list
            building.remove(type)
            rest(type)
            return list
        }
        builds[type] = task
        return task
    }

    /// Keeps `refresh` off `type` for `refreshInterval`. No list of the type lands meanwhile,
    /// since a build starts only once a type stops resting.
    private func rest(_ type: UTType) {
        resting.insert(type)
        let clock = clock
        let interval = refreshInterval
        Task {
            do {
                try await clock.sleep(for: interval)
            } catch {
                preconditionFailure("the clock failed a wait with \(error)")
            }
            resting.remove(type)
        }
    }

    /// Asks for the icons of `apps` not yet asked for at their path and version, and returns
    /// when every one has landed or `iconWait` has passed, so an icon that never comes holds the
    /// list back no longer than that.
    private func waitForIcons(of apps: [App]) async {
        let systemActions = systemActions
        for app in apps where iconsAsked.insert(app.iconKey).inserted {
            let url = app.url
            let key = app.iconKey
            Task {
                let icon = await systemActions.applicationIcon(at: url)
                iconLanded(icon, for: key)
            }
        }
        let keys = apps.map(\.iconKey)
        guard !keys.allSatisfy(iconsLanded.contains) else { return }
        let id = UUID()
        let clock = clock
        let wait = iconWait
        await withCheckedContinuation { continuation in
            let timer = Task {
                do {
                    try await clock.sleep(for: wait)
                } catch is CancellationError {
                    return
                } catch {
                    preconditionFailure("the clock failed a wait with \(error)")
                }
                stopWaiting(id)
            }
            iconWaiters[id] = IconWaiter(keys: keys, continuation: continuation, timer: timer)
        }
    }

    private func iconLanded(_ icon: CGImage?, for key: [String]) {
        iconsLanded.insert(key)
        icons[key] = icon
        for (id, waiter) in iconWaiters where waiter.keys.allSatisfy(iconsLanded.contains) {
            stopWaiting(id)
        }
    }

    private func stopWaiting(_ id: UUID) {
        guard let waiter = iconWaiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume()
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
            app.icon = icons[app.iconKey]
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
