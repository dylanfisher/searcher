import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

/// Settings for a test that never changes one, over a `temporarySuite` under the temporary
/// directory. Nothing is written, so nothing is left. TestSupport can't build `Settings`, which
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

/// A width of another type, a Boolean among them, or one outside the range a grip can drag to
/// reads as the default and is removed.
@MainActor @Test func aColumnWidthOfAnotherShapeIsDiscarded() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let key = Settings.Key.columnWidth.rawValue
    for stored: Any in [
        "300", true, Settings.columnWidths.lowerBound - 1, Settings.columnWidths.upperBound + 1,
        Double.nan,
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
