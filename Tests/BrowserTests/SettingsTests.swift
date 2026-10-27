import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

/// Settings for a test that never changes one, over a `temporarySuite` under the temporary
/// directory, which removes its file with the settings. TestSupport can't build `Settings`, which
/// is in Browser, so each test target has this and `storedSettings`.
@MainActor
func untouchedSettings() -> Settings {
    Settings(defaults: temporarySuite(in: FileManager.default.temporaryDirectory.path))
}

/// `untouchedSettings` with folder sizes on, for a test of the walks that setting starts.
@MainActor
func sizedSettings() -> Settings {
    let settings = untouchedSettings()
    settings.folderSizes = true
    return settings
}

/// Settings stored in `folder`, which takes the suite's file with it when the test removes it.
@MainActor
func storedSettings(in folder: TemporaryFolder) -> Settings {
    Settings(defaults: temporarySuite(in: folder.url.path))
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

    let settings = Settings(defaults: defaults)

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

        let settings = Settings(defaults: defaults, home: "/Users/u")

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
    Settings(defaults: try #require(UserDefaults(suiteName: name))).favorites = favorites

    let relaunched = Settings(defaults: try #require(UserDefaults(suiteName: name)))

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

        let settings = Settings(defaults: defaults)

        #expect(settings.appearance == .auto, "\(stored)")
        #expect(defaults.object(forKey: key) == nil, "\(stored)")
    }
}

@MainActor @Test func settingsSurviveARelaunch() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let name = folder.url.appending(path: "preferences").path
    let first = Settings(defaults: try #require(UserDefaults(suiteName: name)))

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

    let relaunched = Settings(defaults: try #require(UserDefaults(suiteName: name)))
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
        Settings(defaults: try #require(UserDefaults(suiteName: name))).appearance = appearance

        let relaunched = Settings(defaults: try #require(UserDefaults(suiteName: name)))

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

        let settings = Settings(defaults: defaults)

        #expect(settings.columnWidth == Settings.defaultColumnWidth)
        #expect(defaults.object(forKey: key) == nil)
    }
}

@MainActor @Test func aColumnWidthAtEitherEndOfTheRangeIsKept() throws {
    let folder = try TemporaryFolder("SettingsTests")
    for width in [Settings.columnWidths.lowerBound, Settings.columnWidths.upperBound] {
        let name = folder.url.appending(path: "preferences-\(width)").path
        Settings(defaults: try #require(UserDefaults(suiteName: name))).columnWidth = width

        let relaunched = Settings(defaults: try #require(UserDefaults(suiteName: name)))

        #expect(relaunched.columnWidth == width)
    }
}

@MainActor @Test func thePalettesPlaceSurvivesARelaunchAndClearingItRemovesIt() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let name = folder.url.appending(path: "preferences").path
    let first = Settings(defaults: try #require(UserDefaults(suiteName: name)))
    #expect(first.palettePlace == nil)

    first.palettePlace = Settings.PalettePlace(x: 0.25, y: 1)
    let relaunched = Settings(defaults: try #require(UserDefaults(suiteName: name)))
    #expect(relaunched.palettePlace == Settings.PalettePlace(x: 0.25, y: 1))

    relaunched.palettePlace = nil
    let defaults = try #require(UserDefaults(suiteName: name))
    #expect(defaults.object(forKey: Settings.Key.palettePlace.rawValue) == nil)
    #expect(Settings(defaults: defaults).palettePlace == nil)
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

        let settings = Settings(defaults: defaults)

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
    let first = Settings(defaults: try #require(UserDefaults(suiteName: name)))
    #expect(first.newWindowFrame == nil)
    #expect(first.newWindowSize == CGSize(width: 900, height: 600))

    first.newWindowFrame = CGRect(x: -40, y: 120.5, width: 1000, height: 700.5)

    let relaunched = Settings(defaults: try #require(UserDefaults(suiteName: name)))
    #expect(relaunched.newWindowFrame == CGRect(x: -40, y: 120.5, width: 1000, height: 700.5))
    #expect(relaunched.newWindowSize == CGSize(width: 1000, height: 700.5))

    relaunched.newWindowFrame = nil
    let cleared = Settings(defaults: try #require(UserDefaults(suiteName: name)))
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

        let settings = Settings(defaults: defaults)

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
        return Settings(defaults: defaults).springLoadingDelay
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

@MainActor @Test func theCommanderPresetsHelpSaysTheFKeysNeedFn() {
    #expect(Settings.commanderFKeysHelp.contains("Fn"))
}

@MainActor @Test func theEmptyPanelsHelpNamesTheMenuItemThatStillShowsIt() {
    #expect(Settings.hideEmptyOperationsPanelHelp.contains("Window ▸ Operations"))
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

        let settings = Settings(defaults: defaults)

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

    let settings = Settings(defaults: defaults)

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

    let settings = Settings(defaults: defaults)

    #expect(settings.shortcuts == [showPalette: ShortcutOverride(primary: .removed)])
}

/// "Default" has one stored form: no entry. A chord equal to the slot's default, or a removed
/// slot with no default, is the default.
@MainActor @Test func anOverrideThatChangesNothingIsNotWritten() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let defaults = temporarySuite(in: folder.url.path)
    let settings = Settings(defaults: defaults)

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
    Settings(defaults: try #require(UserDefaults(suiteName: name))).shortcuts = shortcuts

    let relaunched = Settings(defaults: try #require(UserDefaults(suiteName: name)))

    #expect(relaunched.shortcuts == shortcuts)
}

@MainActor @Test func changingShortcutsNotifiesObservers() {
    let settings = untouchedSettings()
    var calls = 0
    settings.observe(for: settings) { calls += 1 }

    settings.shortcuts = [showPalette: ShortcutOverride(primary: .removed)]
    settings.shortcuts = [:]

    #expect(calls == 2)
}
