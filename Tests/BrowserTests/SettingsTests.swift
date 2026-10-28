import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

/// Settings over `defaults`, and the lines they log as they remove values of another shape.
@MainActor
private func settingsLogging(_ defaults: UserDefaults, home: String = NSHomeDirectory())
    -> (Settings, [String])
{
    var lines: [String] = []
    let settings = Settings(defaults: defaults, home: home, log: { lines.append($0) })
    return (settings, lines)
}

@MainActor @Test func aMissingKeyReadsAsTheDefault() {
    let settings = untouchedSettings()

    #expect(!settings.showHidden)
    #expect(!settings.foldersFirst)
    #expect(!settings.folderSizes)
    #expect(settings.terminalBundleID == "com.apple.Terminal")
    #expect(!settings.commanderFKeys)
    #expect(settings.hideEmptyOperationsPanel)
    #expect(settings.columnWidth == 286)
    #expect(settings.appearance == .auto)
    #expect(settings.hideDSStore)
    #expect(settings.columnsStartAtHome)
    #expect(settings.home == NSHomeDirectory())
    #expect(settings.favorites == Favorite.defaults(home: NSHomeDirectory()))
    #expect(settings.showsFavoritesInSidebar)
    #expect(settings.showsLocationsInSidebar)
    #expect(settings.showsWorkspacesInSidebar)
}

/// A favorites list of any other shape, or with any one item of another shape or a path twice,
/// is removed whole and reads as the defaults.
@MainActor @Test func favoritesOfAnotherShapeAreDiscardedWhole() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let key = Settings.Key.favorites.rawValue
    let good: [String: Any] = ["path": "/a", "bookmark": Data([1])]
    let malformed: [Any] = [
        "/a", 1, ["path": "/a"], [good, "/b"], [good, ["path": "b"]],
        [good, ["path": "/b", "bookmark": "x"]], [good, ["path": "/b", "name": "b"]],
        [good, ["path": "/A"]], [["bookmark": Data([1])]],
    ]
    for stored in malformed {
        let defaults = temporarySuite(in: folder.url.path)
        defaults.set(stored, forKey: key)

        let (settings, logged) = settingsLogging(defaults, home: "/Users/u")
        #expect(logged.count == 1 && logged[0].contains(key), "\(stored)")

        #expect(settings.favorites == Favorite.defaults(home: "/Users/u"), "\(stored)")
        #expect(defaults.object(forKey: key) == nil, "\(stored)")
    }
}

@MainActor @Test func favoritesSurviveARelaunchWithAndWithoutBookmarks() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let name = folder.url.appending(path: "preferences").path
    let favorites = [
        Favorite(path: "/b", bookmark: Data([1, 2])), Favorite(path: "/a"),
    ]
    Settings(defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)
        .favorites = favorites

    let relaunched = Settings(
        defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)

    #expect(relaunched.favorites == favorites)
}

@MainActor @Test func thePalettesPlaceSurvivesARelaunchAndClearingItRemovesIt() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let name = folder.url.appending(path: "preferences").path
    let first = Settings(
        defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)
    #expect(first.palettePlace == nil)

    first.palettePlace = Settings.PalettePlace(x: 0.25, y: 1)
    let relaunched = Settings(
        defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)
    #expect(relaunched.palettePlace == Settings.PalettePlace(x: 0.25, y: 1))

    relaunched.palettePlace = nil
    let defaults = try #require(UserDefaults(suiteName: name))
    #expect(defaults.object(forKey: Settings.Key.palettePlace.rawValue) == nil)
    #expect(Settings(defaults: defaults, log: unexpectedSettingsLog).palettePlace == nil)
}

/// Anything but two numbers within 0 and 1 reads as no place, the palette's own, and is removed:
/// a place beyond a screen's room can't be put on one.
@MainActor @Test func aPalettePlaceOfAnotherShapeIsDiscarded() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let key = Settings.Key.palettePlace.rawValue
    for stored: Any in [
        [0.5], [0.5, 0.5, 0.5], ["0.5", 0.5], [true, 0.5], [0.5, false], [-0.1, 0.5],
        [0.5, 1.1], [Double.nan, 0.5], [0.5, Double.infinity], 0.5, "0.5,0.5",
        ["x": 0.5, "y": 0.5],
    ] {
        let defaults = temporarySuite(in: folder.url.path)
        defaults.set(stored, forKey: key)

        let (settings, logged) = settingsLogging(defaults)
        #expect(logged.count == 1 && logged[0].contains(key), "\(stored)")

        #expect(settings.palettePlace == nil, "\(stored)")
        #expect(defaults.object(forKey: key) == nil, "\(stored)")
    }
}

@MainActor @Test func aPalettePlaceIsOnlyMadeFromSharesWithinZeroAndOne() {
    #expect(Settings.PalettePlace(x: 0, y: 0) != nil)
    #expect(Settings.PalettePlace(x: 1, y: 1) != nil)
    for (x, y) in [(-0.01, 0.5), (0.5, 1.01), (Double.nan, 0.5), (0.5, -Double.infinity)] {
        #expect(Settings.PalettePlace(x: x, y: y) == nil, "\(x), \(y)")
    }
}

@MainActor @Test func theNewWindowFrameIsUnsetUntilSetAndSurvivesARelaunch() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let name = folder.url.appending(path: "preferences").path
    let first = Settings(
        defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)
    #expect(first.newWindowFrame == nil)
    #expect(first.newWindowSize == CGSize(width: 900, height: 600))

    first.newWindowFrame = CGRect(x: -40, y: 120.5, width: 1000, height: 700.5)

    let relaunched = Settings(
        defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)
    #expect(relaunched.newWindowFrame == CGRect(x: -40, y: 120.5, width: 1000, height: 700.5))
    #expect(relaunched.newWindowSize == CGSize(width: 1000, height: 700.5))

    relaunched.newWindowFrame = nil
    let cleared = Settings(
        defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)
    #expect(cleared.newWindowFrame == nil)
}

@MainActor @Test func aNewWindowFrameOfAnotherShapeIsDiscarded() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let key = Settings.Key.newWindowFrame.rawValue
    for stored: Any in [
        [800], [0, 0, 800], [0, 0, 800, 600, 1], [0, 0, "800", 600], [true, 0, 800, 600],
        [0, 0, 0, 600], [0, 0, 800, -1], [Double.nan, 0, 800, 600], [0, Double.infinity, 800, 600],
        [0, 0, Double.nan, 600], [0, 0, 800, Double.infinity], 800, "0 0 800 600",
        ["x": 0, "y": 0, "width": 800, "height": 600],
    ] {
        let defaults = temporarySuite(in: folder.url.path)
        defaults.set(stored, forKey: key)

        let (settings, logged) = settingsLogging(defaults)
        #expect(logged.count == 1 && logged[0].contains(key), "\(stored)")

        #expect(settings.newWindowFrame == nil, "\(stored)")
        #expect(defaults.object(forKey: key) == nil, "\(stored)")
    }
}

@MainActor @Test func aChangeReachesEveryPane() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let settings = storedSettings(in: folder)
    let entries = [file("a"), file(".hidden")]
    let left = PaneFixture(at: "/left", folders: ["/left": entries], settings: settings)
    let right = PaneFixture(at: "/right", folders: ["/right": entries], settings: settings)
    await settle { left.pane.state.isLoaded && right.pane.state.isLoaded }
    #expect(left.pane.state.names == ["a"])
    #expect(right.pane.state.names == ["a"])

    settings.showHidden = true

    await settle {
        left.pane.state.names.contains(".hidden") && right.pane.state.names.contains(".hidden")
    }
}

/// The suite reads through to the global domain, where the system keeps its Spring-loading
/// setting; a value in the suite stands in for the system's.
/// With hidden files shown, .DS_Store stays hidden in every pane until the setting is turned
/// off, and hides again when it is turned back on.
@MainActor @Test func hidingDSStoreReachesEveryPaneWhileHiddenFilesShow() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let settings = storedSettings(in: folder)
    settings.showHidden = true
    let entries = [file("a"), file(".DS_Store"), file(".hidden")]
    let left = PaneFixture(at: "/left", folders: ["/left": entries], settings: settings)
    let right = PaneFixture(at: "/right", folders: ["/right": entries], settings: settings)
    await settle { left.pane.state.isLoaded && right.pane.state.isLoaded }
    #expect(left.pane.state.names == [".hidden", "a"])
    #expect(right.pane.state.names == [".hidden", "a"])

    settings.hideDSStore = false
    await settle {
        left.pane.state.names == [".DS_Store", ".hidden", "a"]
            && right.pane.state.names == [".DS_Store", ".hidden", "a"]
    }

    settings.hideDSStore = true
    await settle {
        left.pane.state.names == [".hidden", "a"] && right.pane.state.names == [".hidden", "a"]
    }
}

@MainActor @Test func theSpringLoadingDelayFollowsTheSystemSetting() throws {
    let folder = try TemporaryFolder("SettingsTests")
    func delay(enabled: Any?, delay: Any?) -> Duration? {
        let defaults = temporarySuite(in: folder.url.path)
        defaults.set(enabled, forKey: Settings.springLoadingEnabledKey)
        defaults.set(delay, forKey: Settings.springLoadingDelayKey)
        return Settings(defaults: defaults, log: unexpectedSettingsLog).springLoadingDelay
    }

    #expect(delay(enabled: true, delay: 1.25) == .milliseconds(1250))
    #expect(delay(enabled: true, delay: 0) == .zero)
    #expect(delay(enabled: false, delay: 1.25) == nil)
    // Values of another shape read as the system's default, and are left where they are.
    #expect(delay(enabled: true, delay: "1") == .milliseconds(500))
    #expect(delay(enabled: true, delay: true) == .milliseconds(500))
    #expect(delay(enabled: true, delay: -1) == .milliseconds(500))
    #expect(delay(enabled: "NO", delay: 1.25) == .milliseconds(1250))
}

// MARK: Shortcuts

private let showPalette = WindowCommands.showPalette.id

@MainActor @Test func missingShortcutsReadAsNoOverrides() {
    #expect(untouchedSettings().shortcuts.isEmpty)
}

/// "Default" has one form: no entry. A chord equal to the slot's default, or a removed slot
/// with no default, is the default.
@MainActor @Test func anOverrideThatChangesNothingIsNotKept() {
    let settings = untouchedSettings()

    settings.shortcuts = [
        showPalette: ShortcutOverride(primary: .chord(KeyChord("k", modifiers: .command))),
        ViewCommands.filter.id: ShortcutOverride(alternate: .removed),
    ]

    #expect(settings.shortcuts.isEmpty)

    settings.shortcuts = [
        showPalette: ShortcutOverride(
            primary: .chord(KeyChord("k", modifiers: .command)), alternate: .removed)
    ]

    #expect(settings.shortcuts == [showPalette: ShortcutOverride(alternate: .removed)])
}

/// The Commander preset gives these an alternate, so removing it means something even while
/// the preset is off.
@MainActor @Test func removingAPresetAlternateIsKept() {
    let settings = untouchedSettings()
    let trash = FileCommands.moveToTrash.id

    settings.shortcuts = [trash: ShortcutOverride(alternate: .removed)]

    #expect(settings.shortcuts == [trash: ShortcutOverride(alternate: .removed)])
}

/// Every pane observes the settings; one closed leaves no entry behind once another observes.
@MainActor @Test func observingSettingsDropsTheObserversWhoseOwnerIsGone() {
    let settings = untouchedSettings()
    do {
        let gone = NSObject()
        settings.observe(for: gone) {}
    }
    let kept = NSObject()

    settings.observe(for: kept) {}

    #expect(settings.observerCount == 1)
}

@MainActor @Test func changingShortcutsNotifiesObservers() {
    let settings = untouchedSettings()
    var calls = 0
    settings.observe(for: settings) { calls += 1 }

    settings.shortcuts = [showPalette: ShortcutOverride(primary: .removed)]
    settings.shortcuts = [:]

    #expect(calls == 2)
}

// MARK: Config file

/// Settings over a suite of their own in `folder`, connected to the config file at `file` as
/// the app connects them, with `watch` and `clock` standing in for FSEvents and time.
@MainActor
private func connected(
    _ file: URL, in folder: TemporaryFolder, defaults: UserDefaults? = nil,
    clock: ManualClock = ManualClock(), watch: ManualWatch = ManualWatch(),
    log: @escaping @Sendable (String) -> Void = { _ in }
) async -> Settings {
    let settings = Settings(
        defaults: defaults ?? temporarySuite(in: folder.url.path), log: unexpectedSettingsLog)
    await settings.connectTestConfig(file, clock: clock, watch: watch, log: log)
    return settings
}

/// Writes `text` over `file` as an editor's atomic save does, and reports the change.
private func save(_ text: String, to file: URL, watch: ManualWatch) throws {
    try Data(text.utf8).write(to: file, options: .atomic)
    watch.change()
}

/// A value for `preference` other than its default, of the kind it takes, as JSON spells it.
private func changedValue(_ preference: Settings.Preference) -> (Settings.Value, String) {
    switch preference.kind {
    case .bool:
        guard case .bool(let bool) = preference.defaultValue else { preconditionFailure() }
        return (.bool(!bool), "\(!bool)")
    case .number: return (.number(412), "412")
    case .choice(let names):
        guard let other = names.first(where: { .string($0) != preference.defaultValue }) else {
            preconditionFailure("\(preference.name) has one choice")
        }
        return (.string(other), "\"\(other)\"")
    case .string: return (.string("com.example.app"), "\"com.example.app\"")
    }
}

@MainActor
private func bindings(_ settings: Settings) throws -> KeyBindings {
    try AppCommands.keyBindings(settings: settings, reserved: [], fixed: [:])
}

/// The preferences UserDefaults held before the config file was the settings aren't read: the
/// file is their one store.
@MainActor @Test func preferencesInUserDefaultsAreNotRead() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let defaults = temporarySuite(in: folder.url.path)
    defaults.set(true, forKey: "showHidden")
    defaults.set("dark", forKey: "appearance")
    defaults.set(["window.showPalette": ["primary": ""]], forKey: "shortcuts")

    let settings = Settings(defaults: defaults, log: unexpectedSettingsLog)

    #expect(!settings.showHidden)
    #expect(settings.appearance == .auto)
    #expect(settings.shortcuts.isEmpty)
}

/// With no file at launch, the settings are written to one, every preference in it, so the
/// user can see each option.
@MainActor @Test func connectingWithNoFileWritesOne() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "searcher/config.json")

    let settings = await connected(file, in: folder)

    #expect(settings.configFile == file)
    #expect(settings.configFileIsDefault)
    #expect(try Data(contentsOf: file) == ConfigFile.data(.init(values: [:], shortcuts: [:])))
}

/// The file's settings apply before `connectConfig` returns, so the windows open with them.
@MainActor @Test func connectingAppliesTheFile() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"show-hidden": true, "appearance": "dark"}"#.utf8).write(to: file)

    let settings = await connected(file, in: folder)

    #expect(settings.showHidden)
    #expect(settings.appearance == .dark)
    #expect(settings.configErrors.isEmpty)
}

/// A change in the app is written `WorkspaceStore.writeDelay` after it, with the others made
/// meanwhile, in one write: the whole file, every preference at its value.
@MainActor @Test func aChangeInTheAppIsWrittenAfterTheDelay() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    let clock = ManualClock()
    let settings = await connected(file, in: folder, clock: clock)
    let launched = try Data(contentsOf: file)

    settings.showHidden = true
    settings.appearance = .dark
    settings.shortcuts = [showPalette: ShortcutOverride(alternate: .removed)]
    clock.advance(by: WorkspaceStore.writeDelay - .milliseconds(1))
    #expect(try Data(contentsOf: file) == launched)
    clock.advance(by: .milliseconds(1))

    let expected = ConfigFile.data(
        .init(
            values: [.showHidden: .bool(true), .appearance: .string("dark")],
            shortcuts: [showPalette: ShortcutOverride(alternate: .removed)]))
    await settle { (try? Data(contentsOf: file)) == expected }
}

/// The app's settings, written to the file, are what the next launch reads from it.
@MainActor @Test func settingsSurviveARelaunchThroughTheFile() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    let first = await connected(file, in: folder)
    first.showHidden = true
    first.foldersFirst = true
    first.folderSizes = true
    first.terminalBundleID = "com.googlecode.iterm2"
    first.commanderFKeys = true
    first.hideEmptyOperationsPanel = false
    first.columnWidth = Settings.columnWidths.upperBound
    first.appearance = .dark
    first.hideDSStore = false
    first.columnsStartAtHome = false
    first.showsFavoritesInSidebar = false
    first.showsLocationsInSidebar = false
    first.showsWorkspacesInSidebar = false
    let shortcuts = [
        showPalette: ShortcutOverride(
            primary: .removed, alternate: .chord(KeyChord("o", modifiers: [.command, .shift]))),
        NavigationCommands.open.id: ShortcutOverride(primary: .chord(KeyChord(.function(3)))),
    ]
    first.shortcuts = shortcuts
    await first.flushConfig()

    let relaunched = await connected(file, in: folder)

    for preference in Settings.preferences {
        #expect(
            relaunched.value(of: preference.key) == first.value(of: preference.key),
            "\(preference.name)")
        #expect(relaunched.value(of: preference.key) != preference.defaultValue)
    }
    #expect(relaunched.shortcuts == shortcuts)
}

/// The walk the plan asks for: each preference changed in the file and saved applies at once,
/// with no relaunch, and tells the observers.
@MainActor @Test func everyPreferenceAppliesLiveFromTheFile() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    let watch = ManualWatch()
    let settings = await connected(file, in: folder, watch: watch)
    var calls = 0
    settings.observe(for: settings) { calls += 1 }

    for preference in Settings.preferences {
        let (value, json) = changedValue(preference)
        let before = calls
        try save("{\"\(preference.name)\": \(json)}", to: file, watch: watch)
        await settle { settings.value(of: preference.key) == value }
        #expect(calls > before, "\(preference.name)")
    }
    #expect(settings.configErrors.isEmpty)
}

/// Shortcuts saved in the file apply at once too, and reach the bindings.
@MainActor @Test func shortcutsApplyLiveFromTheFile() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    let watch = ManualWatch()
    let settings = await connected(file, in: folder, watch: watch)
    let chord = KeyChord("j", modifiers: [.control, .option, .command])

    try save(
        #"{"shortcuts": {"window.showPalette": {"alternate": "ctrl+opt+cmd+j", "primary": ""}}}"#,
        to: file, watch: watch)
    await settle { !settings.shortcuts.isEmpty }

    #expect(try bindings(settings).chords(of: showPalette) == .init(primary: nil, alternate: chord))
}

/// A file with an error is shown and not applied, the last good settings stay, and a change
/// made in the app meanwhile applies in memory but never writes over the user's broken edit.
/// Once the file is fixed, that change stays, since the fixed file leaves its key as it was,
/// and is written; the fixed file wins the keys it changed.
@MainActor @Test func aBrokenFileIsShownAndNeverWrittenOver() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"show-hidden": true}"#.utf8).write(to: file)
    let watch = ManualWatch()
    let settings = await connected(file, in: folder, watch: watch)
    let broken = "{\n  \"show-hidden\": false,\n  \"folders-first\": tru\n"

    try save(broken, to: file, watch: watch)
    await settle { !settings.configErrors.isEmpty }
    #expect(settings.configErrors.map(\.line) == [3])
    #expect(settings.showHidden)

    settings.foldersFirst = true
    await settings.flushConfig()
    #expect(settings.foldersFirst)
    #expect(try String(contentsOf: file, encoding: .utf8) == broken)

    try save(#"{"hide-ds-store": false}"#, to: file, watch: watch)
    await settle { settings.configErrors.isEmpty }
    #expect(!settings.hideDSStore)
    #expect(!settings.showHidden)
    #expect(settings.foldersFirst)
    await settings.flushConfig()
    let load = configLoad(try String(contentsOf: file, encoding: .utf8))
    #expect(load.values[.foldersFirst] == .bool(true))
    #expect(load.values[.hideDSStore] == .bool(false))
}

/// A file deleted while the app runs means the defaults; the next change in the app writes a
/// file again.
@MainActor @Test func aDeletedFileMeansTheDefaults() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    try Data(#"{"show-hidden": true}"#.utf8).write(to: file)
    let watch = ManualWatch()
    let clock = ManualClock()
    let settings = await connected(file, in: folder, clock: clock, watch: watch)

    try FileManager.default.removeItem(at: file)
    watch.change()
    // A file found gone is read again a moment later before it counts as deleted.
    await settle { clock.waitingSleeps > 0 }
    clock.advance(by: ConfigStore.confirmDelay)
    await settle { !settings.showHidden }
    #expect(!FileManager.default.fileExists(atPath: file.path))

    settings.foldersFirst = true
    await settings.flushConfig()
    #expect(
        try Data(contentsOf: file)
            == ConfigFile.data(.init(values: [.foldersFirst: .bool(true)], shortcuts: [:])))
}

/// The app's own write reaching the watch reads back as nothing new, so it never undoes a
/// change made after it.
@MainActor @Test func theAppsOwnWriteDoesNotReload() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    let watch = ManualWatch()
    var changes = 0
    let settings = await connected(file, in: folder, watch: watch)
    settings.observe(for: settings) { changes += 1 }

    settings.showHidden = true
    await settings.flushConfig()
    settings.foldersFirst = true
    watch.change()
    await settings.flushConfig()
    watch.change()
    await settings.flushConfig()

    #expect(settings.showHidden && settings.foldersFirst)
    #expect(changes == 2)
    #expect(
        try Data(contentsOf: file)
            == ConfigFile.data(
                .init(
                    values: [.showHidden: .bool(true), .foldersFirst: .bool(true)], shortcuts: [:]
                )))
}

/// Choosing a place that has a config file reads it: the settings come from it.
@MainActor @Test func movingToAPlaceWithAFilePullsIt() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    let dropbox = folder.url.appending(path: "Dropbox")
    try FileManager.default.createDirectory(at: dropbox, withIntermediateDirectories: true)
    let chosen = dropbox.appending(path: "searcher.json")
    try Data(#"{"show-hidden": true}"#.utf8).write(to: chosen)
    let defaults = temporarySuite(in: folder.url.path)
    let settings = await connected(file, in: folder, defaults: defaults)
    settings.foldersFirst = true

    await settings.moveConfig(to: chosen)

    #expect(settings.configFile == chosen)
    #expect(!settings.configFileIsDefault)
    #expect(settings.showHidden)
    #expect(!settings.foldersFirst)
    #expect(try Data(contentsOf: chosen) == Data(#"{"show-hidden": true}"#.utf8))
    // The default file got the change made before the move.
    #expect(
        configLoad(try String(contentsOf: file, encoding: .utf8)).values[.foldersFirst]
            == .bool(true))

    // The place outlives the app; Use Default goes back, and its file is read again.
    let relaunched = await connected(file, in: folder, defaults: defaults)
    #expect(relaunched.configFile == chosen)
    #expect(relaunched.showHidden)
    await relaunched.useDefaultConfigFile()
    #expect(relaunched.configFile == file)
    #expect(relaunched.configFileIsDefault)
    #expect(relaunched.foldersFirst)
    #expect(!relaunched.showHidden)
}

/// Choosing a folder with no config file in it saves the settings there, as `config.json`.
@MainActor @Test func movingToAnEmptyFolderSavesThere() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    let dropbox = folder.url.appending(path: "Dropbox")
    try FileManager.default.createDirectory(at: dropbox, withIntermediateDirectories: true)
    let settings = await connected(file, in: folder)
    settings.foldersFirst = true

    await settings.moveConfig(to: dropbox)

    let moved = dropbox.appending(path: "config.json")
    #expect(settings.configFile == moved)
    #expect(settings.foldersFirst)
    #expect(
        try Data(contentsOf: moved)
            == ConfigFile.data(.init(values: [.foldersFirst: .bool(true)], shortcuts: [:])))
}

/// A place whose folder isn't there, as on a volume that isn't connected, is shown as an error,
/// and the settings stay as they are; the default place isn't used in its stead, at once or at
/// the next launch.
@MainActor @Test func aPlaceOnAMissingVolumeIsReportedNotReplaced() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    let defaults = temporarySuite(in: folder.url.path)
    let settings = await connected(file, in: folder, defaults: defaults)
    settings.foldersFirst = true
    let away = folder.url.appending(path: "Volumes/Backup/config.json")

    await settings.moveConfig(to: away)

    #expect(settings.configFile == away)
    #expect(settings.configErrors.first?.reason.contains("isn't there") == true)
    #expect(settings.foldersFirst)

    let relaunched = await connected(file, in: folder, defaults: defaults)
    #expect(relaunched.configFile == away)
    #expect(!relaunched.configErrors.isEmpty)
}

/// A write that waits until the test opens it, as one to a share that hangs does.
private final class HeldWrite: Sendable {
    private let gate = DispatchSemaphore(value: 0)
    /// One entry each time a write starts, and one in `finished` each time one ends.
    let started = EventLog<Void>()
    let finished = EventLog<Void>()

    var write: ConfigStore.Write {
        { data, url, check in
            self.started.append(())
            self.gate.wait()
            try AtomicWrite.write(data, to: url, beforeRename: check)
            self.finished.append(())
        }
    }

    /// Lets one waiting write go on.
    func open() { gate.signal() }
}

/// Settings over a file in `folder` whose writes wait on `held`.
@MainActor
private func heldSettings(_ folder: TemporaryFolder, held: HeldWrite, clock: ManualClock) async
    -> (Settings, URL)
{
    let file = folder.url.appending(path: "config.json")
    try? Data("{}".utf8).write(to: file)
    let settings = Settings(
        defaults: temporarySuite(in: folder.url.path), log: unexpectedSettingsLog)
    await settings.connectTestConfig(file, clock: clock, write: held.write)
    return (settings, file)
}

/// A flush while the delayed write is already running waits for it, rather than returning
/// with the change not yet on disk, as quitting would.
@MainActor @Test func aFlushWaitsForTheWriteRunning() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let held = HeldWrite()
    let clock = ManualClock()
    let (settings, file) = await heldSettings(folder, held: held, clock: clock)
    settings.showHidden = true
    clock.advance(by: WorkspaceStore.writeDelay)
    await settle { held.started.all.count == 1 }

    let flushStarted = EventLog<Void>()
    let flush = Task { @MainActor in
        flushStarted.append(())
        await settings.flushConfig()
        return held.finished.all.count
    }
    await settle { !flushStarted.all.isEmpty }
    held.open()

    #expect(await flush.value == 1)
    #expect(
        configLoad(try String(contentsOf: file, encoding: .utf8)).values[.showHidden] == .bool(true)
    )
}

/// A flush whose write hangs ends at its deadline, so quitting goes on without it; the write
/// keeps going.
@MainActor @Test func aFlushThatHangsEndsAtItsDeadline() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let held = HeldWrite()
    let clock = ManualClock()
    let (settings, _) = await heldSettings(folder, held: held, clock: clock)
    settings.showHidden = true

    let flushed = Task { @MainActor in
        await settings.flushConfig(by: clock.now.advanced(by: .seconds(2)), clock: clock)
    }
    await settle { held.started.all.count == 1 }
    clock.advance(by: .seconds(2))

    // Bounded only to catch a flush that ignores its deadline, which would hang here.
    #expect(await bounded(flushed) == false)
    #expect(held.finished.all.isEmpty)
    held.open()
    await settle { held.finished.all.count == 1 }
}

/// An edit of the file that changes another key, saved while a change made in the app waits
/// on its write's delay, keeps that change: both are in the settings and then in the file.
@MainActor @Test func anEditOfAnotherKeyKeepsAChangeNotYetWritten() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    try Data("{}".utf8).write(to: file)
    let watch = ManualWatch()
    let settings = await connected(file, in: folder, watch: watch)
    let alternate = KeyChord("o", modifiers: [.command, .shift, .option])

    settings.showHidden = true
    settings.shortcuts = [showPalette: ShortcutOverride(alternate: .chord(alternate))]
    try save(
        #"{"folders-first": true, "shortcuts": {"window.showPalette": {"primary": ""}}}"#,
        to: file, watch: watch)
    await settle { settings.foldersFirst }

    #expect(settings.showHidden)
    #expect(
        settings.shortcuts == [
            showPalette: ShortcutOverride(primary: .removed, alternate: .chord(alternate))
        ])
    await settings.flushConfig()
    let load = configLoad(try String(contentsOf: file, encoding: .utf8))
    #expect(load.values[.showHidden] == .bool(true))
    #expect(load.values[.foldersFirst] == .bool(true))
    #expect(load.shortcuts == settings.shortcuts)
}

/// An edit of the same key, or the same shortcut slot, wins over the change made in the app.
@MainActor @Test func anEditOfTheSameKeyWinsOverAChangeNotYetWritten() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    try Data("{}".utf8).write(to: file)
    let watch = ManualWatch()
    let settings = await connected(file, in: folder, watch: watch)

    settings.appearance = .light
    settings.shortcuts = [showPalette: ShortcutOverride(primary: .removed)]
    try save(
        #"{"appearance": "dark", "shortcuts": {"window.showPalette": {"primary": "cmd+j"}}}"#,
        to: file, watch: watch)
    await settle { settings.appearance == .dark }

    let cmdJ = KeyChord("j", modifiers: .command)
    #expect(settings.shortcuts == [showPalette: ShortcutOverride(primary: .chord(cmdJ))])
    await settings.flushConfig()
    let load = configLoad(try String(contentsOf: file, encoding: .utf8))
    #expect(load.values == [.appearance: .string("dark")])
}

/// A file that can't be saved shows its error until a save succeeds.
@MainActor @Test func aFailedSaveIsShown() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    try Data("{}".utf8).write(to: file)
    let settings = Settings(
        defaults: temporarySuite(in: folder.url.path), log: unexpectedSettingsLog)
    await settings.connectTestConfig(
        file, write: { _, _, _ in throw CocoaError(.fileWriteNoPermission) })

    settings.showHidden = true
    await settings.flushConfig()

    await settle { !settings.configErrors.isEmpty }
    #expect(settings.configErrors.first?.reason.hasPrefix("couldn't be saved") == true)
}

/// Every command can be given a chord no command has through the file, all in one file: the
/// plan's walk of the registry.
@MainActor @Test func everyCommandCanBeReboundThroughTheFile() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config.json")
    let defaults = try bindings(untouchedSettings())
    let modifiers: [KeyChord.Modifiers] = [
        [.control, .option, .shift], [.control, .option, .command, .shift],
        [.control, .option, .command],
    ]
    let keys: [KeyChord.Key] =
        "abcdefghijklmnopqrstuvwxyz0123456789".map { .character($0) }
        + KeyChord.functionKeys.map { .function($0) }
    let free = modifiers.flatMap { held in keys.map { KeyChord($0, modifiers: held) } }
        .filter { defaults.registry.command(for: $0) == nil }
    let commands = AppCommands.commands
    #expect(free.count >= commands.count)
    let given = Dictionary(uniqueKeysWithValues: zip(commands.map(\.id), free))
    let shortcuts = commands.map { command in
        "\"\(command.id)\": {\"primary\": \"\(given[command.id]?.stored ?? "")\"}"
    }.joined(separator: ",\n")
    try Data("{\"shortcuts\": {\(shortcuts)}}".utf8).write(to: file)

    let settings = await connected(file, in: folder)

    #expect(settings.configErrors.isEmpty, "\(settings.configErrors)")
    let rebound = try bindings(settings)
    for command in commands {
        let chord = try #require(given[command.id])
        #expect(rebound.registry.command(for: chord)?.id == command.id)
        #expect(rebound.chords(of: command.id).primary == chord)
    }
}

/// Each preference is declared once: one key in the file each. Only preferences a user sets
/// are in the file; state the app keeps by itself is not.
@MainActor @Test func eachPreferenceIsDeclaredOnce() {
    let names = Settings.preferences.map(\.name)
    let keys = Settings.preferences.map(\.key)
    #expect(Set(names).count == names.count)
    #expect(Set(keys).count == keys.count)
    #expect(!names.contains(ConfigFile.shortcutsKey))
    #expect(
        Set(keys) == [
            .showHidden, .hideDSStore, .columnsStartAtHome, .foldersFirst, .folderSizes,
            .terminalBundleID, .commanderFKeys, .hideEmptyOperationsPanel, .columnWidth,
            .appearance, .showsFavoritesInSidebar, .showsLocationsInSidebar,
            .showsWorkspacesInSidebar,
        ])
}
