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
            for id in Set(shortcuts.keys).union(oldValue.keys) {
                for position in ShortcutOverride.Position.allCases
                where (shortcuts[id]?[position] ?? .standard)
                    != (oldValue[id]?[position] ?? .standard)
                {
                    markUnsaved(.slot(id, position))
                }
            }
            changed()
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

    /// What `connectConfig` was given.
    private struct Connection {
        let defaultFile: URL
        let startWait: DeadlineWait.Start
        let makeStore: MakeConfigStore
    }

    private var connection: Connection?
    /// The store of the config file in use.
    private var configStore: ConfigStore?
    /// The generation of the last read of the file applied, which a write is based on.
    private var configGeneration = 0
    /// Counts the writes, so the store drops one that arrives after a later one.
    private var saveSequence = 0
    /// The wait before the next write, which starts with the first change not yet written.
    private var scheduledSave: Task<Void, Never>?
    /// The write running now and those queued after it, which a flush waits for.
    private var saving: Task<Void, Never>?

    /// A preference or a shortcut slot.
    private enum Change: Hashable {
        case value(Key)
        case slot(CommandID, ShortcutOverride.Position)
    }

    /// The changes made in the app that the file doesn't hold yet, each with the count of
    /// changes when it was last made, so a write clears only the changes it carried.
    private var unsaved: [Change: Int] = [:]
    private var changeCount = 0
    /// What the file held at the last read applied or write made: what a read is compared with
    /// to tell the keys it changed from those it left.
    private var fileContents = ConfigFile.Contents(values: [:], shortcuts: [:])
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

    /// Reads the config file at the location the user chose, or else at `defaultFile`, through
    /// a store `makeStore` makes, and applies it before it returns, so windows opened after it
    /// open with the file's settings; with no file there it writes one from the settings. Then
    /// applies each later read as it comes, and writes each change made in the app
    /// `WorkspaceStore.writeDelay` after the first one not yet written, timed on `clock`.
    public func connectConfig<C: Clock<Duration>>(
        defaultFile: URL, clock: C = ContinuousClock(), makeStore: @escaping MakeConfigStore
    ) async {
        precondition(connection == nil, "the config file is already connected")
        connection = Connection(
            defaultFile: defaultFile, startWait: DeadlineWait.make(on: clock),
            makeStore: makeStore)
        await use(chosenConfigFile ?? defaultFile)
    }

    /// Keeps the config file at `chosen`, or in it as `ConfigFile.name` when it is a folder,
    /// from now on: a file there is read and applied, and with none the settings are written
    /// there. A file there with an error is shown and not written over, and the settings stay
    /// as they are.
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

    /// Writes the changes waiting for their delay now, as quitting needs, after the write
    /// running now. With none waiting it writes nothing, so a file the app hasn't changed keeps
    /// the user's text.
    public func flushConfig() async {
        scheduledSave?.cancel()
        scheduledSave = nil
        if unsaved.isEmpty {
            await saving?.value
        } else {
            await saveConfig()
        }
    }

    /// `flushConfig`, unless `deadline` on `clock` passes first, as when the app quits and the
    /// file is on a share whose write hangs. Returns whether the flush finished; one that
    /// didn't keeps going.
    public func flushConfig<C: Clock<Duration>>(by deadline: C.Instant, clock: C) async -> Bool {
        await FirstToFinish.run(by: deadline, clock: clock) { await self.flushConfig() }
    }

    /// Makes the config file from the settings when there is none, as Open Config File needs,
    /// and says whether there is a file to open.
    func makeConfigFileIfMissing() async -> Bool {
        guard let store = configStore else { preconditionFailure("no config file is connected") }
        return await store.makeIfMissing(configContents, basedOn: configGeneration)
    }

    /// Applies `load`, read as `generation`: its values and shortcuts, every default when there
    /// is no file, or, for a file with an error, the errors, which leave the settings as they
    /// were. Tells the observers when anything changed.
    ///
    /// A change made in the app and not yet written stays when the file left its key as it
    /// was, and is written over the file's; the file wins a key both changed.
    func applyConfig(_ load: ConfigLoad, generation: Int) {
        configGeneration = generation
        let before = (Self.preferences.map { value(of: $0.key) }, shortcuts, readErrors)
        switch load.outcome {
        case .missing:
            merge(ConfigFile.Contents(values: [:], shortcuts: [:]))
            readErrors = []
        case .values(let values, let shortcuts):
            merge(
                ConfigFile.Contents(
                    values: values, shortcuts: Self.normalized(shortcuts, changedFrom: [:])))
            readErrors = []
        case .failed(let errors):
            readErrors = errors
        }
        if before != (Self.preferences.map { value(of: $0.key) }, shortcuts, readErrors) {
            notifyObservers()
        }
    }

    /// Takes `file`'s settings, with the changes the app hasn't written on top of them where
    /// `file` left their keys as `fileContents` had them, and schedules the write of those.
    private func merge(_ file: ConfigFile.Contents) {
        var values = file.values
        var shortcuts = file.shortcuts
        for change in unsaved.keys {
            switch change {
            case .value(let key):
                if Self.value(of: key, in: file) == Self.value(of: key, in: fileContents) {
                    values[key] = self.values[key]
                } else {
                    unsaved[change] = nil
                }
            case .slot(let id, let position):
                if (file.shortcuts[id]?[position] ?? .standard)
                    == (fileContents.shortcuts[id]?[position] ?? .standard)
                {
                    shortcuts[id, default: ShortcutOverride()][position] =
                        self.shortcuts[id]?[position] ?? .standard
                } else {
                    unsaved[change] = nil
                }
            }
        }
        fileContents = file
        self.values = values
        isApplyingConfig = true
        self.shortcuts = Self.normalized(shortcuts, changedFrom: [:])
        isApplyingConfig = false
        if unsaved.isEmpty {
            scheduledSave?.cancel()
            scheduledSave = nil
        } else {
            scheduleSave()
        }
    }

    /// Preference `key` as `contents` sets it, or its default.
    private static func value(of key: Key, in contents: ConfigFile.Contents) -> Value? {
        contents.values[key] ?? preferencesByKey[key]?.defaultValue
    }

    /// Switches to the store of `file`, after writing what the last one has waiting: reads it,
    /// and applies the read, or with no file writes the settings there.
    private func use(_ file: URL) async {
        guard let connection else { preconditionFailure("no config file is connected") }
        if let old = configStore {
            await flushConfig()
            await old.stop()
        }
        let store = connection.makeStore(file, file == connection.defaultFile)
        configStore = store
        readErrors = []
        saveFailure = nil
        // A file at the new place wins whole; with none, the settings are written there.
        unsaved = [:]
        fileContents = configContents
        let updates = store.updates
        let first = await store.start()
        guard configStore === store else { return }
        configGeneration = 0
        if first == .missing {
            await saveConfig()
        } else {
            applyConfig(first, generation: 0)
        }
        // The file, its errors or the settings may have changed.
        notifyObservers()
        Task { [weak self] in
            for await update in updates {
                guard let self, configStore === store else { return }
                switch update {
                case .read(let load, let generation):
                    applyConfig(load, generation: generation)
                case .saved(let failure):
                    guard failure != saveFailure else { continue }
                    saveFailure = failure
                    notifyObservers()
                }
            }
        }
    }

    /// What a write of the config file holds now.
    private var configContents: ConfigFile.Contents {
        ConfigFile.Contents(values: values, shortcuts: shortcuts)
    }

    /// Records `change` as made in the app and not yet in the file.
    private func markUnsaved(_ change: Change) {
        changeCount += 1
        unsaved[change] = changeCount
    }

    /// Tells the observers of a change made in the app, and schedules its write.
    private func changed() {
        notifyObservers()
        scheduleSave()
    }

    /// Writes the settings to the config file `WorkspaceStore.writeDelay` after the first
    /// change not yet written, so a burst of changes costs one write.
    private func scheduleSave() {
        guard let connection, configStore != nil, scheduledSave == nil else { return }
        let wait = connection.startWait(WorkspaceStore.writeDelay)
        scheduledSave = Task { [weak self] in
            guard await DeadlineWait.reached(wait), let self, !Task.isCancelled else { return }
            scheduledSave = nil
            await saveConfig()
        }
    }

    /// Writes the settings, after any write already running, and returns once it is done.
    private func saveConfig() async {
        let previous = saving
        let write = Task { [weak self] in
            await previous?.value
            await self?.writeConfig()
        }
        saving = write
        await write.value
        if saving == write { saving = nil }
    }

    /// Hands the settings to the store to write. A write that holds them clears the changes
    /// it carried; one the store refuses keeps them. A read on its way merges them then; with
    /// none, as when the file was found gone and not yet confirmed so or the write failed, the
    /// write is tried again after the delay, unless the file has an error, which only an edit
    /// of it clears.
    private func writeConfig() async {
        guard let store = configStore else { return }
        saveSequence += 1
        let contents = configContents
        let carried = unsaved
        let generation = configGeneration
        let saved = await store.save(contents, basedOn: generation, sequence: saveSequence)
        guard configStore === store, configGeneration == generation else { return }
        if saved {
            fileContents = contents
            for (change, count) in carried where unsaved[change] == count {
                unsaved[change] = nil
            }
        } else if !unsaved.isEmpty, readErrors.isEmpty {
            scheduleSave()
        }
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
        markUnsaved(.value(key))
        changed()
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
