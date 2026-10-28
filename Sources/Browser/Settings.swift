import Base
import Foundation

/// The app's preferences, and the only type that reads or writes them. Each is app-wide: every
/// pane applies the same value, and a change reaches every pane.
///
/// The user's preferences, those in `preferences`, and their shortcuts live in the config file
/// (docs/decisions/0123-config-is-the-settings.md), which `connectConfig` reads, watches and
/// writes: a change in the app is written to the file, and a save of the file applies at once.
/// Until one is connected, as in the tests and the UI bench, they live in memory only.
///
/// The state the app keeps by itself, such as the favorites, the window frame, the palette's
/// place and where the config file is, lives in a `UserDefaults` suite the owner passes in, so
/// tests and the UI bench never touch the user's own. A key that is missing reads as its
/// default. A value of the wrong type is removed, logged, and reads as the default too: stored
/// data has one shape.
@MainActor
public final class Settings {
    enum Key: String {
        case showHidden
        case hideDSStore
        case columnsStartAtHome
        case foldersFirst
        case folderSizes
        case terminalBundleID
        case commanderFKeys
        case hideEmptyOperationsPanel
        case columnWidth
        case appearance
        case palettePlace
        case newWindowFrame
        case favorites
        case showsFavoritesInSidebar
        case showsLocationsInSidebar
        case showsWorkspacesInSidebar
        case configFile
    }

    /// Where the palette's panel sits on a screen, as Spotlight remembers where it was dragged
    /// (0087-palette-window.md). Each share is of the room the panel leaves on the screen's
    /// visible area, so a place puts the panel wholly on any screen it fits.
    public struct PalettePlace: Equatable, Sendable {
        /// 0 puts the panel against the screen's left edge, 1 against its right.
        public let x: Double
        /// 0 puts the panel's top against the top of the visible area, 1 its bottom against the
        /// bottom.
        public let y: Double

        /// The place at `x` and `y`; nil unless both are within 0 and 1.
        public init?(x: Double, y: Double) {
            guard Self.shares.contains(x), Self.shares.contains(y) else { return nil }
            self.x = x
            self.y = y
        }

        static let shares: ClosedRange<Double> = 0...1
    }

    /// Whether the app is light or dark. Auto follows the system's setting, as it changes.
    public enum Appearance: String, CaseIterable, Sendable {
        case auto
        case light
        case dark
    }

    /// The preferences a user sets, each with its key in the config file, what it accepts and
    /// its default: the one list the config file's keys, its checks and what the app writes
    /// are made from. The shortcuts, which have a shape of their own, and the state the app
    /// keeps by itself, such as the favorites, window frames and the palette's place, aren't in
    /// it.
    public nonisolated static let preferences: [Preference] = [
        Preference(
            .showHidden, "show-hidden", .bool, default: .bool(false)),
        Preference(
            .hideDSStore, "hide-ds-store", .bool, default: .bool(true)),
        Preference(
            .foldersFirst, "folders-first", .bool, default: .bool(false)),
        Preference(
            .folderSizes, "folder-sizes", .bool, default: .bool(false)),
        Preference(
            .columnsStartAtHome, "columns-start-at-home", .bool, default: .bool(true)),
        Preference(
            .columnWidth, "column-width",
            .number(
                isValid: isColumnWidth,
                described:
                    "a whole number from \(Int(columnWidths.lowerBound)) to \(Int(columnWidths.upperBound))"
            ),
            default: .number(defaultColumnWidth)),
        Preference(
            .appearance, "appearance", .choice(Appearance.allCases.map(\.rawValue)),
            default: .string(Appearance.auto.rawValue)),
        Preference(
            .terminalBundleID, "terminal-bundle-id", .string,
            default: .string("com.apple.Terminal")),
        Preference(
            .commanderFKeys, "commander-f-keys", .bool, default: .bool(false)),
        Preference(
            .hideEmptyOperationsPanel, "hide-empty-operations-panel", .bool,
            default: .bool(true)),
        Preference(
            .showsFavoritesInSidebar, "sidebar-favorites", .bool, default: .bool(true)),
        Preference(
            .showsLocationsInSidebar, "sidebar-locations", .bool, default: .bool(true)),
        Preference(
            .showsWorkspacesInSidebar, "sidebar-workspaces", .bool, default: .bool(true)),
    ]

    /// `preferences` by key.
    nonisolated static let preferencesByKey = Dictionary(
        uniqueKeysWithValues: preferences.map { ($0.key, $0) })

    /// The config file's default location in `home`.
    public nonisolated static func userConfigFile(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appending(
            path: ".config/searcher/\(ConfigFile.name)")
    }

    /// The width a new column of column view gets until one is set, and the width an
    /// Option-double-click puts fitted columns back to (0096-column-widths.md).
    public nonisolated static let defaultColumnWidth = 286.0
    /// The widths a column's grip can drag it to (0096-column-widths.md).
    public nonisolated static let columnWidths: ClosedRange<Double> = 100...1000

    /// Whether `width` is one a column can have: whole points, so the columns sit on the pixel
    /// grid, within `columnWidths` (0096-column-widths.md).
    public nonisolated static func isColumnWidth(_ width: Double) -> Bool {
        columnWidths.contains(width) && width == width.rounded()
    }

    /// The widths the preview's grip can drag it to: up to a column's widest, but no narrower
    /// than keeps the Information rows' titles whole and a word of each value on a line
    /// (0090-preview-column.md).
    public nonisolated static let previewWidths = 200...columnWidths.upperBound

    /// Whether `width` is one the preview can have: a column width within `previewWidths`.
    public nonisolated static func isPreviewWidth(_ width: Double) -> Bool {
        previewWidths.contains(width) && isColumnWidth(width)
    }

    /// The content size a new window gets until a window is resized by hand
    /// (0057-windows-and-tear-out.md).
    public nonisolated static let defaultWindowSize = CGSize(width: 900, height: 600)

    /// Whether `size` is one a window can have: finite and not empty.
    public nonisolated static func isWindowSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    /// Whether `frame` is one a new window can open at: finite, with a size `isWindowSize(_:)`
    /// accepts.
    public nonisolated static func isWindowFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && isWindowSize(frame.size)
    }

    /// Whether panes list hidden entries: names starting with a dot, and entries with the hidden
    /// flag (`chflags hidden`). Off by default.
    public var showHidden: Bool {
        get { bool(.showHidden) }
        set { set(.bool(newValue), for: .showHidden) }
    }
    /// Whether panes leave out entries named exactly `.DS_Store` even while `showHidden` lists
    /// the other hidden entries. On by default (0100-appearance-and-ds-store.md). It hides them
    /// from the rows only: copying, moving or trashing a folder takes its `.DS_Store` along.
    public var hideDSStore: Bool {
        get { bool(.hideDSStore) }
        set { set(.bool(newValue), for: .hideDSStore) }
    }
    /// Whether column view's trail for a folder in `home` starts at `home`, as Finder's does,
    /// rather than at the root of the folder's volume. On by default
    /// (0103-column-trail-from-the-root.md).
    public var columnsStartAtHome: Bool {
        get { bool(.columnsStartAtHome) }
        set { set(.bool(newValue), for: .columnsStartAtHome) }
    }
    /// The user's home folder: the folder `~` names in a typed path, a new window opens at and
    /// `columnsStartAtHome` starts trails at. It isn't stored.
    public let home: String
    /// Whether folders come before every other entry in each sort. Off by default.
    public var foldersFirst: Bool {
        get { bool(.foldersFirst) }
        set { set(.bool(newValue), for: .foldersFirst) }
    }
    /// Whether a pane in list view walks each subfolder for its size and shows it, on local and
    /// network volumes alike: Finder's Calculate All Sizes. Off by default, as in Finder, so
    /// browsing reads no more of the disk than the listings.
    public var folderSizes: Bool {
        get { bool(.folderSizes) }
        set { set(.bool(newValue), for: .folderSizes) }
    }
    /// The bundle ID of the app Open Terminal Here opens the pane's folder in. Terminal by default.
    public var terminalBundleID: String {
        get { string(.terminalBundleID) }
        set { set(.string(newValue), for: .terminalBundleID) }
    }
    /// Whether the Commander F-key preset is on: F5 to F8 are the default alternates of the file
    /// commands in `FileCommands.commanderFKeys`. Off by default.
    public var commanderFKeys: Bool {
        get { bool(.commanderFKeys) }
        set { set(.bool(newValue), for: .commanderFKeys) }
    }

    /// Whether a window's operations panel hides once it has no operations left, as Finder shows
    /// none while idle. Off, the panel stays and says "No operations". On by default.
    public var hideEmptyOperationsPanel: Bool {
        get { bool(.hideEmptyOperationsPanel) }
        set { set(.bool(newValue), for: .hideEmptyOperationsPanel) }
    }

    /// The width, in points, every new column of column view gets, and the preview with them,
    /// in every window. An Option-drag or Option-double-click of a column's grip sets it, as in
    /// Finder; a plain one resizes its column alone (0096-column-widths.md). `defaultColumnWidth`
    /// by default.
    ///
    /// - Precondition: `isColumnWidth(_:)` holds for it.
    public var columnWidth: Double {
        get { number(.columnWidth) }
        set {
            precondition(
                Self.isColumnWidth(newValue),
                "column width \(newValue) is not a whole number within \(Self.columnWidths)")
            set(.number(newValue), for: .columnWidth)
        }
    }

    /// Whether the app is light, dark or follows the system. Auto by default.
    public var appearance: Appearance {
        get {
            let name = string(.appearance)
            guard let appearance = Appearance(rawValue: name) else {
                preconditionFailure("appearance holds \(name), which no appearance is named")
            }
            return appearance
        }
        set { set(.string(newValue.rawValue), for: .appearance) }
    }

    /// The sidebar's Favorites, top to bottom, every path distinct by
    /// `Favorite.areDistinct(_:)`; Finder's defaults (`Favorite.defaults(home:)`) until the list
    /// is first changed. Only `Favorites` changes it (docs/decisions/0107-sidebar-favorites.md).
    ///
    /// - Precondition: no path is in it twice.
    public var favorites: [Favorite] {
        didSet {
            precondition(
                Favorite.areDistinct(favorites.map(\.path)), "a favorite is listed twice")
            store(favorites.map(\.stored), for: .favorites, changed: favorites != oldValue)
        }
    }

    /// Whether the sidebar shows its Favorites group. On by default.
    public var showsFavoritesInSidebar: Bool {
        get { bool(.showsFavoritesInSidebar) }
        set { set(.bool(newValue), for: .showsFavoritesInSidebar) }
    }

    /// Whether the sidebar shows its Locations group. On by default.
    public var showsLocationsInSidebar: Bool {
        get { bool(.showsLocationsInSidebar) }
        set { set(.bool(newValue), for: .showsLocationsInSidebar) }
    }

    /// Whether the sidebar shows its Workspaces group. On by default.
    public var showsWorkspacesInSidebar: Bool {
        get { bool(.showsWorkspacesInSidebar) }
        set { set(.bool(newValue), for: .showsWorkspacesInSidebar) }
    }

    /// The user's changes to the commands' chords, by command; empty by default. Each override
    /// is kept in one form: a slot set to its default is `.standard`, and an override with both
    /// slots `.standard` is left out, so it is never written
    /// (docs/decisions/0106-primary-and-alternate-shortcuts.md). The config file holds them
    /// under `shortcuts`. `KeyBindings` applies them.
    ///
    /// - Precondition: every ID is a command's in `AppCommands.commands`.
    public var shortcuts: [CommandID: ShortcutOverride] = [:] {
        didSet {
            guard !isApplyingConfig else { return }
            let normal = Self.normalized(shortcuts, changedFrom: oldValue)
            if normal != shortcuts {
                isApplyingConfig = true
                shortcuts = normal
                isApplyingConfig = false
            }
            guard shortcuts != oldValue else { return }
            notifyObservers()
            for id in Set(shortcuts.keys).union(oldValue.keys) {
                for position in ShortcutOverride.Position.allCases {
                    let slot = shortcuts[id]?[position] ?? .standard
                    if slot != oldValue[id]?[position] ?? .standard {
                        send(.slot(id, position, slot))
                    }
                }
            }
        }
    }

    /// Where the palette's panel opens, on the screen of the window that opens it; nil for its
    /// own place, centered near the top. Dragging the panel sets it. No pane follows it, so a
    /// change notifies no one.
    public var palettePlace: PalettePlace? {
        didSet {
            guard palettePlace != oldValue else { return }
            let key = Key.palettePlace.rawValue
            if let place = palettePlace {
                defaults.set([place.x, place.y], forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// The frame a new window opens at: the origin of the window's frame and the size of its
    /// content, as the window last had them when the user finished resizing it by an edge or
    /// moving it by its title bar, as in Finder (0057-windows-and-tear-out.md). Nil until then.
    /// No pane follows it, so a change notifies no one.
    ///
    /// - Precondition: `isWindowFrame(_:)` holds for it.
    public var newWindowFrame: CGRect? {
        didSet {
            guard newWindowFrame != oldValue else { return }
            let key = Key.newWindowFrame.rawValue
            if let frame = newWindowFrame {
                precondition(Self.isWindowFrame(frame), "window frame \(frame) is empty")
                defaults.set(
                    [frame.origin.x, frame.origin.y, frame.width, frame.height], forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// The content size a new window opens at: that of `newWindowFrame`, `defaultWindowSize`
    /// until one is set.
    public var newWindowSize: CGSize {
        newWindowFrame?.size ?? Self.defaultWindowSize
    }

    /// How long a drag has to hover over a folder before it springs open, as the system's
    /// Spring-loading setting in Accessibility ▸ Pointer Control has it; nil while that setting is
    /// off. The system writes both keys to the global domain, which every suite reads through, and
    /// the app never writes them. A missing key or one of another type reads as the system's
    /// default, on and 0.5 s; it isn't removed, since the key isn't the app's.
    public var springLoadingDelay: Duration? {
        let enabled = defaults.object(forKey: Self.springLoadingEnabledKey)
        if let enabled = enabled as? NSNumber, Self.isBoolean(enabled), !enabled.boolValue {
            return nil
        }
        let delay = defaults.object(forKey: Self.springLoadingDelayKey)
        guard let delay = delay as? NSNumber, !Self.isBoolean(delay),
            delay.doubleValue >= 0, delay.doubleValue.isFinite
        else { return Self.defaultSpringLoadingDelay }
        return .seconds(delay.doubleValue)
    }
    /// The system's keys for its Spring-loading setting, and its default delay.
    static let springLoadingEnabledKey = "com.apple.springing.enabled"
    static let springLoadingDelayKey = "com.apple.springing.delay"
    static let defaultSpringLoadingDelay: Duration = .milliseconds(500)

    private let defaults: UserDefaults
    private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor () -> Void
    }

    /// The preferences' values, the config file's or set in the app since; a preference
    /// missing from it reads as its default.
    private var values: [Key: Value] = [:]
    /// Whether a read of the config file is being applied, which is no change to write back.
    private var isApplyingConfig = false

    /// The settings stored in `defaults`, for the user whose home folder is `home`. `log` gets
    /// each stored value removed for its shape as the settings are read.
    public init(defaults: UserDefaults, home: String = NSHomeDirectory(), log: (String) -> Void) {
        self.defaults = defaults
        self.home = home
        palettePlace = Self.palettePlace(in: defaults, log: log)
        newWindowFrame = Self.windowFrame(in: defaults, log: log)
        favorites = Self.favorites(in: defaults, log: log) ?? Favorite.defaults(home: home)
        chosenConfigFile = Self.chosenConfigFile(in: defaults, log: log)
    }

    // MARK: Config file

    /// Makes the store of the config file at `file`; `isDefault` says whether it is the default
    /// location, whose folder the store may make.
    public typealias MakeConfigStore = @MainActor (_ file: URL, _ isDefault: Bool) -> ConfigStore

    /// How long a move of the config file waits for the old place's writes before it hands
    /// what is left to the new place, so an old place on a share that hangs can't hold the move.
    public static let moveWait: Duration = .seconds(2)

    /// What `connectConfig` was given.
    private struct Connection {
        let defaultFile: URL
        /// Runs the work until it ends or the time given passes on the connection's clock, and
        /// says whether it ended.
        let within: @Sendable (Duration, @escaping @Sendable () async -> Void) async -> Bool
        let makeStore: MakeConfigStore
    }

    private var connection: Connection?
    /// The store of the config file in use.
    private var configStore: ConfigStore?
    /// The changes made in the app and sent to the store but not yet in the file, in order,
    /// each with its sequence number. A read of the file is applied with them on top, so one
    /// the store hasn't taken yet isn't undone, and a move hands them to the new place.
    private var unwritten: [(sequence: Int, patch: ConfigPatch)] = []
    private var sequence = 0
    /// The highest sequence number sent to the store in use, 0 for none: what a wait for its
    /// writes waits for. A store counts only what it was sent, so a new one starts at 0.
    private var sentToStore = 0
    /// The config file the user chose, which `UserDefaults` keeps as a path, since it can't
    /// live in the file it names; nil for the default location.
    private var chosenConfigFile: URL?
    /// What kept the last read of the file from being applied.
    private var readErrors: [ConfigError] = []
    /// Why the last write of the file failed; nil once one succeeds.
    private var saveFailure: ConfigError?

    /// The config file the settings are read from and written to; nil until `connectConfig`
    /// runs, and for settings that never connect one, as the tests' and the UI bench's.
    public var configFile: URL? { configStore?.file }

    /// Whether `configFile` is at the default location rather than one the user chose.
    public var configFileIsDefault: Bool { chosenConfigFile == nil }

    /// What is wrong with the config file as last read, which kept it from being applied, and
    /// why the last write of it failed; empty while it applies and saves, or there is none.
    public var configErrors: [ConfigError] { readErrors + (saveFailure.map { [$0] } ?? []) }

    /// The keys of the changes made in the app that aren't in the config file yet, as the file
    /// names them, for the log when quitting goes on without them.
    public var unwrittenConfigKeys: [String] { unwritten.map(\.patch.key) }

    /// Reads the config file at the location the user chose, or else at `defaultFile`, through
    /// a store `makeStore` makes, and applies it before it returns, so windows opened after it
    /// open with the file's settings; with no file there it writes one from the settings. Then
    /// applies each later read as it comes, and hands each change made in the app to the store,
    /// which writes it at once. `clock` times a move's wait for the old place.
    public func connectConfig<C: Clock<Duration>>(
        defaultFile: URL, clock: C = ContinuousClock(), makeStore: @escaping MakeConfigStore
    ) async {
        precondition(connection == nil, "the config file is already connected")
        connection = Connection(
            defaultFile: defaultFile,
            within: { limit, work in
                await FirstToFinish.run(by: clock.now.advanced(by: limit), clock: clock, work)
            }, makeStore: makeStore)
        await use(chosenConfigFile ?? defaultFile)
    }

    /// Keeps the config file at `chosen`, or in it as `ConfigFile.name` when it is a folder,
    /// from now on: a file there is read and applied, and with none the settings are written
    /// there. The changes not yet written at the old place are written at the new one, on top.
    /// A file there with an error is shown and not written over, and the settings stay as they
    /// are.
    public func moveConfig(to chosen: URL) async {
        let file = await Task.detached { ConfigStore.file(forChosen: chosen) }.value
        guard let connection else { preconditionFailure("no config file is connected") }
        if file == connection.defaultFile {
            await useDefaultConfigFile()
            return
        }
        defaults.set(file.path, forKey: Key.configFile.rawValue)
        chosenConfigFile = file
        await use(file)
    }

    /// Keeps the config file at the default location from now on, as `moveConfig` does.
    public func useDefaultConfigFile() async {
        guard let connection else { preconditionFailure("no config file is connected") }
        defaults.removeObject(forKey: Key.configFile.rawValue)
        chosenConfigFile = nil
        await use(connection.defaultFile)
    }

    /// Returns once every change made in the app so far is in the config file, or the store
    /// has stopped.
    public func flushConfig() async {
        guard let store = configStore else { return }
        let through = sentToStore
        await store.waitUntilWritten(through: through)
        if configStore === store {
            unwritten.removeAll { $0.sequence <= through }
        }
    }

    /// `flushConfig`, unless `deadline` on `clock` passes first, as when the app quits and the
    /// file is on a share whose write hangs or has an error the user hasn't fixed. Returns
    /// whether every change reached the file; one that didn't keeps going.
    public func flushConfig<C: Clock<Duration>>(by deadline: C.Instant, clock: C) async -> Bool {
        await FirstToFinish.run(by: deadline, clock: clock) { await self.flushConfig() }
    }

    /// Makes the config file from the settings when there is none, as Open Config File needs,
    /// and says whether there is a file to open.
    func makeConfigFileIfMissing() async -> Bool {
        guard let store = configStore else { preconditionFailure("no config file is connected") }
        return await store.makeIfMissing(configContents)
    }

    /// Applies `load`: its values and shortcuts, every default when there is no file, or, for
    /// a file with an error, the errors, which leave the settings as they were. The changes
    /// made in the app and not yet written are applied on top, so a read the store sent before
    /// it took one doesn't undo it. Tells the observers when anything changed.
    func applyConfig(_ load: ConfigLoad) {
        let before = (Self.preferences.map { value(of: $0.key) }, shortcuts, readErrors)
        switch load.outcome {
        case .missing:
            replace(with: ConfigFile.Contents(values: [:], shortcuts: [:]))
            readErrors = []
        case .values(let values, let shortcuts):
            replace(with: ConfigFile.Contents(values: values, shortcuts: shortcuts))
            readErrors = []
        case .failed(let errors):
            readErrors = errors
        }
        if before != (Self.preferences.map { value(of: $0.key) }, shortcuts, readErrors) {
            notifyObservers()
        }
    }

    /// Takes `contents` as the settings, with the changes not yet written on top.
    private func replace(with contents: ConfigFile.Contents) {
        var contents = contents
        for (_, patch) in unwritten { patch.apply(to: &contents) }
        values = contents.values
        isApplyingConfig = true
        shortcuts = Self.normalized(contents.shortcuts, changedFrom: [:])
        isApplyingConfig = false
    }

    /// Switches to the store of `file`: waits up to `moveWait` for the old one to write what it
    /// has, hands what is left to the new one, then reads the file, and applies the read, or
    /// with no file writes the settings there.
    private func use(_ file: URL) async {
        guard let connection else { preconditionFailure("no config file is connected") }
        if let old = configStore {
            let through = sentToStore
            if await connection.within(
                Self.moveWait,
                {
                    await old.waitUntilWritten(through: through)
                })
            {
                unwritten.removeAll { $0.sequence <= through }
            }
            // Not waited for: an old place on a share that hangs would hold the move.
            Task { await old.stop() }
        }
        let store = connection.makeStore(file, file == connection.defaultFile)
        configStore = store
        readErrors = []
        saveFailure = nil
        sentToStore = 0
        for (sequence, patch) in unwritten {
            store.send(patch, sequence: sequence)
            sentToStore = sequence
        }
        let updates = store.updates
        let first = await store.start(writingIfMissing: configContents)
        guard configStore === store else { return }
        applyConfig(first)
        // The file, its errors or the settings may have changed.
        notifyObservers()
        Task { [weak self] in
            for await update in updates {
                guard let self, configStore === store else { return }
                switch update {
                case .read(let load):
                    applyConfig(load)
                case .wrote(let through):
                    unwritten.removeAll { $0.sequence <= through }
                case .saved(let failure):
                    guard failure != saveFailure else { continue }
                    saveFailure = failure
                    notifyObservers()
                }
            }
        }
    }

    /// What the settings write to a config file made new.
    private var configContents: ConfigFile.Contents {
        ConfigFile.Contents(values: values, shortcuts: shortcuts)
    }

    /// Hands `patch`, a change made in the app, to the store, which writes it into the file at
    /// once; nothing before a config file is connected.
    private func send(_ patch: ConfigPatch) {
        guard connection != nil else { return }
        sequence += 1
        unwritten.append((sequence, patch))
        guard let store = configStore else { return }
        store.send(patch, sequence: sequence)
        sentToStore = sequence
    }

    /// Runs `handler` after each change of a setting, for as long as `owner` exists.
    public func observe(for owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    /// How many observers are kept, those whose owner is gone among them. Tests read it.
    var observerCount: Int { observers.count }

    private func store(_ value: Any, for key: Key, changed: Bool) {
        guard changed else { return }
        defaults.set(value, forKey: key.rawValue)
        notifyObservers()
    }

    /// The value of preference `key`, or its default.
    func value(of key: Key) -> Value {
        guard let preference = Self.preferencesByKey[key] else {
            preconditionFailure("\(key) isn't a preference")
        }
        return values[key] ?? preference.defaultValue
    }

    private func bool(_ key: Key) -> Bool {
        guard case .bool(let bool) = value(of: key) else {
            preconditionFailure("\(key) holds \(value(of: key)), not a Boolean")
        }
        return bool
    }

    private func number(_ key: Key) -> Double {
        guard case .number(let number) = value(of: key) else {
            preconditionFailure("\(key) holds \(value(of: key)), not a number")
        }
        return number
    }

    private func string(_ key: Key) -> String {
        guard case .string(let string) = value(of: key) else {
            preconditionFailure("\(key) holds \(value(of: key)), not a string")
        }
        return string
    }

    /// Sets preference `key` to `value` when that changes it, tells the observers and writes
    /// the config file.
    private func set(_ value: Value, for key: Key) {
        guard value != self.value(of: key) else { return }
        values[key] = value
        notifyObservers()
        send(.value(key, value))
    }

    private func notifyObservers() {
        observers.removeAll { $0.owner == nil }
        for observer in observers {
            observer.handler()
        }
    }

    /// Whether `number` is a Boolean. A Boolean reads back as an NSNumber, as integers do; only
    /// CFBoolean is one.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// The config file the user chose, stored under its key as an absolute path; nil when there
    /// is none, or it is anything else, which is removed.
    private static func chosenConfigFile(in defaults: UserDefaults, log: (String) -> Void) -> URL? {
        let key = Key.configFile.rawValue
        guard let value = defaults.object(forKey: key) else { return nil }
        if let path = value as? String, path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        discard(key, holding: value, in: defaults, log: log)
        return nil
    }

    /// The palette's place stored under its key, two numbers within 0 and 1; nil when there is
    /// none, or it is anything else, which is removed.
    private static func palettePlace(in defaults: UserDefaults, log: (String) -> Void)
        -> PalettePlace?
    {
        let key = Key.palettePlace.rawValue
        guard let value = defaults.object(forKey: key) else { return nil }
        if let shares = value as? [Any], shares.count == 2,
            let x = shares[0] as? NSNumber, !isBoolean(x),
            let y = shares[1] as? NSNumber, !isBoolean(y),
            let place = PalettePlace(x: x.doubleValue, y: y.doubleValue)
        {
            return place
        }
        discard(key, holding: value, in: defaults, log: log)
        return nil
    }

    /// The window frame stored under its key, four numbers `isWindowFrame(_:)` accepts; nil when
    /// there is none, or it is anything else, which is removed.
    private static func windowFrame(in defaults: UserDefaults, log: (String) -> Void) -> CGRect? {
        let key = Key.newWindowFrame.rawValue
        guard let value = defaults.object(forKey: key) else { return nil }
        if let sides = value as? [Any], sides.count == 4 {
            let numbers = sides.compactMap { side -> Double? in
                guard let number = side as? NSNumber, !isBoolean(number) else { return nil }
                return number.doubleValue
            }
            if numbers.count == 4,
                case let frame = CGRect(
                    x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]),
                isWindowFrame(frame)
            {
                return frame
            }
        }
        discard(key, holding: value, in: defaults, log: log)
        return nil
    }

    /// The favorites stored under their key: a list of `Favorite`s in their stored shape, no path
    /// twice. Nil when there is none, or when it or any item in it has another shape, and the
    /// whole list is removed: one item's shape can't be trusted apart from the list's.
    private static func favorites(in defaults: UserDefaults, log: (String) -> Void) -> [Favorite]? {
        let key = Key.favorites.rawValue
        guard let value = defaults.object(forKey: key) else { return nil }
        if let list = value as? [Any] {
            let favorites = list.compactMap(Favorite.init(stored:))
            if favorites.count == list.count, Favorite.areDistinct(favorites.map(\.path)) {
                return favorites
            }
        }
        discard(key, holding: value, in: defaults, log: log)
        return nil
    }

    /// Every command by ID.
    private static let commands = Dictionary(
        AppCommands.commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// `shortcuts` with each override that differs from `old`'s
    /// `ShortcutOverride.normalized(for:preset:)`, and those that change nothing left out.
    ///
    /// - Precondition: each ID whose override differs from `old`'s is a command's.
    private static func normalized(
        _ shortcuts: [CommandID: ShortcutOverride], changedFrom old: [CommandID: ShortcutOverride]
    ) -> [CommandID: ShortcutOverride] {
        var normal = shortcuts
        for (id, override) in shortcuts where old[id] != override {
            guard let command = commands[id] else {
                preconditionFailure("no command has the ID \(id)")
            }
            let kept = override.normalized(for: command, preset: FileCommands.commanderFKeys[id])
            normal[id] = kept.isStandard ? nil : kept
        }
        return normal
    }

    /// Removes `key`, whose stored `value` has another shape than its setting's, and logs it, so
    /// a setting that reads as its default never does so unexplained.
    private static func discard(
        _ key: String, holding value: Any, in defaults: UserDefaults, log: (String) -> Void
    ) {
        defaults.removeObject(forKey: key)
        log("discarded the setting \(key), which held \(value) of another shape than its own")
    }
}
