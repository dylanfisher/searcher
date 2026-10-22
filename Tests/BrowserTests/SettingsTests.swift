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

/// Settings stored in `folder`, which takes the suite's file with it when the test removes it.
@MainActor
func storedSettings(in folder: TemporaryFolder) -> Settings {
    Settings(defaults: temporarySuite(in: folder.url.path))
}

@MainActor @Test func aMissingKeyReadsAsTheDefault() {
    let settings = untouchedSettings()

    #expect(!settings.showHidden)
    #expect(!settings.foldersFirst)
    #expect(settings.folderSizes)
    #expect(settings.terminalBundleID == "com.apple.Terminal")
}

@MainActor @Test func aWrongTypedValueIsDiscardedNotCoerced() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let defaults = temporarySuite(in: folder.url.path)
    // UserDefaults' own `bool(forKey:)` reads both of these as true.
    defaults.set("YES", forKey: Settings.Key.showHidden.rawValue)
    defaults.set(1, forKey: Settings.Key.foldersFirst.rawValue)
    defaults.set(0, forKey: Settings.Key.folderSizes.rawValue)
    defaults.set(7, forKey: Settings.Key.terminalBundleID.rawValue)

    let settings = Settings(defaults: defaults)

    #expect(!settings.showHidden)
    #expect(!settings.foldersFirst)
    #expect(settings.folderSizes)
    #expect(defaults.object(forKey: Settings.Key.folderSizes.rawValue) == nil)
    #expect(defaults.object(forKey: Settings.Key.showHidden.rawValue) == nil)
    #expect(defaults.object(forKey: Settings.Key.foldersFirst.rawValue) == nil)
    #expect(settings.terminalBundleID == "com.apple.Terminal")
    #expect(defaults.object(forKey: Settings.Key.terminalBundleID.rawValue) == nil)
}

@MainActor @Test func settingsSurviveARelaunch() throws {
    let folder = try TemporaryFolder("SettingsTests")
    let name = folder.url.appending(path: "preferences").path
    let first = Settings(defaults: try #require(UserDefaults(suiteName: name)))

    first.showHidden = true
    first.foldersFirst = true
    first.folderSizes = false
    first.terminalBundleID = "com.googlecode.iterm2"

    let relaunched = Settings(defaults: try #require(UserDefaults(suiteName: name)))
    #expect(relaunched.showHidden)
    #expect(relaunched.foldersFirst)
    #expect(!relaunched.folderSizes)
    #expect(relaunched.terminalBundleID == "com.googlecode.iterm2")
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
