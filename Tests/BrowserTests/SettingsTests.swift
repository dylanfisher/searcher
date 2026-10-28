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

@MainActor @Test func aWrongTypedValueIsDiscardedNotCoerced() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let defaults = temporarySuite(in: folder.url.path)
    // UserDefaults' own `bool(forKey:)` reads both of these as true.
    defaults.set("YES", forKey: Settings.Key.showHidden.rawValue)
    defaults.set(1, forKey: Settings.Key.foldersFirst.rawValue)
    defaults.set(1, forKey: Settings.Key.folderSizes.rawValue)
    defaults.set(7, forKey: Settings.Key.terminalBundleID.rawValue)
    defaults.set(0, forKey: Settings.Key.hideDSStore.rawValue)
    defaults.set("NO", forKey: Settings.Key.columnsStartAtHome.rawValue)
    defaults.set(0, forKey: Settings.Key.showsFavoritesInSidebar.rawValue)
    defaults.set("NO", forKey: Settings.Key.showsLocationsInSidebar.rawValue)
    defaults.set("NO", forKey: Settings.Key.showsWorkspacesInSidebar.rawValue)

    let (settings, logged) = settingsLogging(defaults)

    let keys: [Settings.Key] = [
        .showHidden, .foldersFirst, .folderSizes, .terminalBundleID, .hideDSStore,
        .columnsStartAtHome, .showsFavoritesInSidebar, .showsLocationsInSidebar,
        .showsWorkspacesInSidebar,
    ]
    #expect(logged.count == keys.count)
    for key in keys {
        #expect(logged.contains { $0.contains("setting \(key.rawValue),") }, "\(key)")
    }
    #expect(!settings.showHidden)
    #expect(!settings.foldersFirst)
    #expect(!settings.folderSizes)
    #expect(defaults.object(forKey: Settings.Key.folderSizes.rawValue) == nil)
    #expect(defaults.object(forKey: Settings.Key.showHidden.rawValue) == nil)
    #expect(defaults.object(forKey: Settings.Key.foldersFirst.rawValue) == nil)
    #expect(settings.terminalBundleID == "com.apple.Terminal")
    #expect(defaults.object(forKey: Settings.Key.terminalBundleID.rawValue) == nil)
    #expect(settings.hideDSStore)
    #expect(defaults.object(forKey: Settings.Key.hideDSStore.rawValue) == nil)
    #expect(settings.columnsStartAtHome)
    #expect(defaults.object(forKey: Settings.Key.columnsStartAtHome.rawValue) == nil)
    #expect(settings.showsFavoritesInSidebar)
    #expect(defaults.object(forKey: Settings.Key.showsFavoritesInSidebar.rawValue) == nil)
    #expect(settings.showsLocationsInSidebar)
    #expect(defaults.object(forKey: Settings.Key.showsLocationsInSidebar.rawValue) == nil)
    #expect(settings.showsWorkspacesInSidebar)
    #expect(defaults.object(forKey: Settings.Key.showsWorkspacesInSidebar.rawValue) == nil)
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

/// An appearance that isn't one of the names `Settings.Appearance` has, or isn't a string,
/// reads as Auto and is removed.
@MainActor @Test func anAppearanceOfAnotherShapeIsDiscarded() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let key = Settings.Key.appearance.rawValue
    for stored: Any in ["purple", "Dark", "", 1, true] {
        let defaults = temporarySuite(in: folder.url.path)
        defaults.set(stored, forKey: key)

        let (settings, logged) = settingsLogging(defaults)
        #expect(logged.count == 1 && logged[0].contains(key), "\(stored)")

        #expect(settings.appearance == .auto, "\(stored)")
        #expect(defaults.object(forKey: key) == nil, "\(stored)")
    }
}

@MainActor @Test func settingsSurviveARelaunch() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let name = folder.url.appending(path: "preferences").path
    let first = Settings(
        defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)

    first.showHidden = true
    first.foldersFirst = true
    first.folderSizes = true
    first.terminalBundleID = "com.googlecode.iterm2"
    first.commanderFKeys = true
    first.hideEmptyOperationsPanel = false
    first.columnWidth = 312
    first.appearance = .dark
    first.hideDSStore = false
    first.columnsStartAtHome = false
    first.showsFavoritesInSidebar = false
    first.showsLocationsInSidebar = false
    first.showsWorkspacesInSidebar = false

    let relaunched = Settings(
        defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)
    #expect(relaunched.showHidden)
    #expect(relaunched.foldersFirst)
    #expect(relaunched.folderSizes)
    #expect(relaunched.terminalBundleID == "com.googlecode.iterm2")
    #expect(relaunched.commanderFKeys)
    #expect(!relaunched.hideEmptyOperationsPanel)
    #expect(relaunched.columnWidth == 312)
    #expect(relaunched.appearance == .dark)
    #expect(!relaunched.hideDSStore)
    #expect(!relaunched.columnsStartAtHome)
    #expect(!relaunched.showsFavoritesInSidebar)
    #expect(!relaunched.showsLocationsInSidebar)
    #expect(!relaunched.showsWorkspacesInSidebar)
}

@MainActor @Test func eachAppearanceSurvivesARelaunch() throws {
    let folder = try TemporaryFolder("SettingsTests")
    for appearance in Settings.Appearance.allCases {
        let name = folder.url.appending(path: "preferences-\(appearance)").path
        Settings(defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)
            .appearance = appearance

        let relaunched = Settings(
            defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)

        #expect(relaunched.appearance == appearance)
    }
}

/// A width of another type, a Boolean among them, a fraction of a point, or one outside the range
/// a grip can drag to reads as the default and is removed.
@MainActor @Test func aColumnWidthOfAnotherShapeIsDiscarded() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let key = Settings.Key.columnWidth.rawValue
    for stored: Any in [
        "300", true, Settings.columnWidths.lowerBound - 1, Settings.columnWidths.upperBound + 1,
        Double.nan, 300.5,
    ] {
        let defaults = temporarySuite(in: folder.url.path)
        defaults.set(stored, forKey: key)

        let (settings, logged) = settingsLogging(defaults)
        #expect(logged.count == 1 && logged[0].contains(key), "\(stored)")

        #expect(settings.columnWidth == Settings.defaultColumnWidth)
        #expect(defaults.object(forKey: key) == nil)
    }
}

@MainActor @Test func aColumnWidthAtEitherEndOfTheRangeIsKept() throws {
    let folder = try TemporaryFolder("SettingsTests")
    for width in [Settings.columnWidths.lowerBound, Settings.columnWidths.upperBound] {
        let name = folder.url.appending(path: "preferences-\(width)").path
        Settings(defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)
            .columnWidth = width

        let relaunched = Settings(
            defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)

        #expect(relaunched.columnWidth == width)
    }
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

private let shortcutsKey = Settings.Key.shortcuts.rawValue
private let showPalette = WindowCommands.showPalette.id

@MainActor @Test func missingShortcutsReadAsNoOverrides() {
    #expect(untouchedSettings().shortcuts.isEmpty)
}

/// Shortcuts of any other shape, or with any one override of another shape, are removed whole.
@MainActor @Test func shortcutsOfAnotherShapeAreDiscardedWhole() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let good = ["alternate": "cmd+shift+o"]
    let malformed: [Any] = [
        "window.showPalette", 1, ["window.showPalette"], ["window.showPalette": "cmd+o"],
        ["window.showPalette": [String: String]()],
        ["window.showPalette": ["third": "cmd+o"]],
        ["window.showPalette": ["primary": 1]],
        ["window.showPalette": ["primary": "shift+cmd+o"]],
        ["window.showPalette": good, "navigation.open": ["primary": "cmd+O"]],
    ]
    for stored in malformed {
        let defaults = temporarySuite(in: folder.url.path)
        defaults.set(stored, forKey: shortcutsKey)

        let (settings, logged) = settingsLogging(defaults)
        #expect(logged.count == 1 && logged[0].contains(shortcutsKey), "\(stored)")

        #expect(settings.shortcuts.isEmpty, "\(stored)")
        #expect(defaults.object(forKey: shortcutsKey) == nil, "\(stored)")
    }
}

/// A renamed command is a change of the code, so its entry goes and the others stay.
@MainActor @Test func anUnknownCommandIDDropsOnlyItsEntry() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let defaults = temporarySuite(in: folder.url.path)
    defaults.set(
        [
            "window.showPalette": ["alternate": "cmd+shift+o"],
            "window.renamedLongAgo": ["primary": "cmd+j"],
        ], forKey: shortcutsKey)

    let (settings, logged) = settingsLogging(defaults)
    #expect(logged.count == 1 && logged[0].contains("window.renamedLongAgo"))

    let alternate = KeyChord("o", modifiers: [.command, .shift])
    #expect(settings.shortcuts == [showPalette: ShortcutOverride(alternate: .chord(alternate))])
    #expect(
        defaults.object(forKey: shortcutsKey) as? [String: [String: String]]
            == ["window.showPalette": ["alternate": "cmd+shift+o"]])
}

@MainActor @Test func anEmptyStringReadsAsARemovedChord() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let defaults = temporarySuite(in: folder.url.path)
    defaults.set(["window.showPalette": ["primary": ""]], forKey: shortcutsKey)

    let settings = Settings(defaults: defaults, log: unexpectedSettingsLog)

    #expect(settings.shortcuts == [showPalette: ShortcutOverride(primary: .removed)])
}

/// "Default" has one stored form: no entry. A chord equal to the slot's default, or a removed
/// slot with no default, is the default.
@MainActor @Test func anOverrideThatChangesNothingIsNotWritten() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let defaults = temporarySuite(in: folder.url.path)
    let settings = Settings(defaults: defaults, log: unexpectedSettingsLog)

    settings.shortcuts = [
        showPalette: ShortcutOverride(primary: .chord(KeyChord("k", modifiers: .command))),
        ViewCommands.filter.id: ShortcutOverride(alternate: .removed),
    ]

    #expect(settings.shortcuts.isEmpty)
    #expect(defaults.object(forKey: shortcutsKey) == nil)

    settings.shortcuts = [
        showPalette: ShortcutOverride(
            primary: .chord(KeyChord("k", modifiers: .command)), alternate: .removed)
    ]

    #expect(settings.shortcuts == [showPalette: ShortcutOverride(alternate: .removed)])
    #expect(
        defaults.object(forKey: shortcutsKey) as? [String: [String: String]]
            == ["window.showPalette": ["alternate": ""]])

    settings.shortcuts = [:]

    #expect(defaults.object(forKey: shortcutsKey) == nil)
}

/// The Commander preset gives these an alternate, so removing it means something even while
/// the preset is off.
@MainActor @Test func removingAPresetAlternateIsKept() {
    let settings = untouchedSettings()
    let trash = FileCommands.moveToTrash.id

    settings.shortcuts = [trash: ShortcutOverride(alternate: .removed)]

    #expect(settings.shortcuts == [trash: ShortcutOverride(alternate: .removed)])
}

@MainActor @Test func shortcutsSurviveARelaunch() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let name = folder.url.appending(path: "preferences").path
    let shortcuts = [
        showPalette: ShortcutOverride(
            primary: .removed, alternate: .chord(KeyChord("o", modifiers: [.command, .shift]))),
        NavigationCommands.open.id: ShortcutOverride(primary: .chord(KeyChord(.function(3)))),
    ]
    Settings(defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)
        .shortcuts = shortcuts

    let relaunched = Settings(
        defaults: try #require(UserDefaults(suiteName: name)), log: unexpectedSettingsLog)

    #expect(relaunched.shortcuts == shortcuts)
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

@MainActor @Test func aFileSettingFoldersFirstAndHiddenFilesGivesBoth() {
    let settings = untouchedSettings()

    settings.applyConfig(ConfigParser.parse("folders-first = true\nshow-hidden = true\n"))

    #expect(settings.foldersFirst)
    #expect(settings.showHidden)
    #expect(settings.configErrors.isEmpty)
}

/// A file with an error isn't applied: the values from before stay, the defaults at launch, and
/// the errors are kept for the banner until a good file loads.
@MainActor @Test func aFileWithAnErrorIsNotApplied() {
    let settings = untouchedSettings()

    settings.applyConfig(ConfigParser.parse("show-hidden = true\nfolders-first = yes"))
    #expect(!settings.showHidden)
    #expect(!settings.foldersFirst)
    #expect(settings.configErrors.map(\.line) == [2])

    settings.applyConfig(ConfigParser.parse("show-hidden = true"))
    settings.applyConfig(ConfigParser.parse("show-hidden = false\ncolumn-width = 1"))
    #expect(settings.showHidden)
    #expect(settings.configErrors.map(\.line) == [2])

    settings.applyConfig(ConfigParser.parse("show-hidden = false"))
    #expect(!settings.showHidden)
    #expect(settings.configErrors.isEmpty)
}

/// No file, as after it is deleted, gives every default back.
@MainActor @Test func noFileMeansEveryDefault() {
    let settings = untouchedSettings()
    settings.applyConfig(
        ConfigParser.parse(
            "show-hidden = true\ncolumn-width = 400\nappearance = dark\nhide-ds-store = false"))
    #expect(settings.columnWidth == 400)

    settings.applyConfig(.missing)

    #expect(!settings.showHidden)
    #expect(settings.columnWidth == Settings.defaultColumnWidth)
    #expect(settings.appearance == .auto)
    #expect(settings.hideDSStore)
    #expect(settings.configErrors.isEmpty)
}

/// A value the app sets is kept in its defaults over the file's, through a relaunch that reads
/// the same file, and the file isn't touched.
@MainActor @Test func aToggleInTheAppOverridesTheFileAndSurvivesARelaunch() async throws {
    let folder = try TemporaryFolder("SettingsTests")
    let file = folder.url.appending(path: "config")
    let bytes = Data("folders-first = false\n".utf8)
    try bytes.write(to: file)
    let name = folder.url.appending(path: "preferences").path
    let first = Settings(
        defaults: try #require(UserDefaults(suiteName: name)), configFile: file,
        log: unexpectedSettingsLog)
    await first.follow(ConfigWatcher(file: file, log: { _ in }, watch: { _, _ in {} }))
    #expect(!first.foldersFirst)

    first.foldersFirst = true
    #expect(first.foldersFirst)

    let relaunched = Settings(
        defaults: try #require(UserDefaults(suiteName: name)), configFile: file,
        log: unexpectedSettingsLog)
    await relaunched.follow(ConfigWatcher(file: file, log: { _ in }, watch: { _, _ in {} }))
    #expect(relaunched.foldersFirst)
    #expect(try Data(contentsOf: file) == bytes)
}

/// The file's value is what an app value overrides, so only a key both set, to different
/// values, is listed; Use Config File Value removes the app's and gives the file's.
@MainActor @Test func anOverrideOfADifferentFileValueIsListedAndCanBeCleared() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let defaults = temporarySuite(in: folder.url.path)
    let settings = Settings(defaults: defaults, log: unexpectedSettingsLog)
    settings.applyConfig(ConfigParser.parse("show-hidden = true\nfolders-first = true"))
    settings.showHidden = false
    settings.foldersFirst = false
    settings.foldersFirst = true
    settings.folderSizes = true
    var calls = 0
    settings.observe(for: settings) { calls += 1 }

    let overrides = settings.configOverrides
    #expect(overrides.map(\.name) == ["show-hidden"])
    #expect(overrides.first?.appValue == .bool(false))
    #expect(overrides.first?.fileValue == .bool(true))

    settings.useConfigValue(for: try #require(overrides.first))

    #expect(settings.showHidden)
    #expect(defaults.object(forKey: Settings.Key.showHidden.rawValue) == nil)
    #expect(settings.configOverrides.isEmpty)
    #expect(calls == 1)
}

/// Observers hear of a load that changes a value or the errors, and not of one that changes
/// nothing.
@MainActor @Test func aLoadNotifiesObserversOnlyOfAChange() {
    let settings = untouchedSettings()
    var calls = 0
    settings.observe(for: settings) { calls += 1 }

    settings.applyConfig(ConfigParser.parse("show-hidden = true"))
    settings.applyConfig(ConfigParser.parse("show-hidden = true # again"))
    #expect(calls == 1)
    settings.applyConfig(ConfigParser.parse("show-hidden = maybe"))
    #expect(calls == 2)
    settings.applyConfig(ConfigParser.parse("show-hidden = maybe"))
    #expect(calls == 2)
    settings.applyConfig(.missing)
    #expect(calls == 3)
}

/// Setting in the app the value the file has removes the app's value rather than storing it, so
/// the preference follows the file again and no override is left behind to outlast it.
@MainActor @Test func settingTheFilesValueInTheAppFollowsTheFileAgain() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let defaults = temporarySuite(in: folder.url.path)
    let settings = Settings(defaults: defaults, log: unexpectedSettingsLog)
    settings.applyConfig(ConfigParser.parse("folders-first = true"))
    settings.foldersFirst = false
    var calls = 0
    settings.observe(for: settings) { calls += 1 }

    settings.foldersFirst = true

    #expect(settings.foldersFirst)
    #expect(defaults.object(forKey: Settings.Key.foldersFirst.rawValue) == nil)
    #expect(calls == 1)
    settings.applyConfig(ConfigParser.parse("folders-first = false"))
    #expect(!settings.foldersFirst)
}

/// Each preference is declared once: one file name and one stored key each. Only preferences a
/// user sets are in the file; state the app keeps by itself is not.
@MainActor @Test func eachPreferenceIsDeclaredOnce() {
    let names = Settings.preferences.map(\.name)
    let keys = Settings.preferences.map(\.key)
    #expect(Set(names).count == names.count)
    #expect(Set(keys).count == keys.count)
    #expect(
        Set(keys) == [
            .showHidden, .hideDSStore, .columnsStartAtHome, .foldersFirst, .folderSizes,
            .terminalBundleID, .commanderFKeys, .hideEmptyOperationsPanel, .columnWidth,
            .appearance, .showsFavoritesInSidebar, .showsLocationsInSidebar,
            .showsWorkspacesInSidebar,
        ])
}
