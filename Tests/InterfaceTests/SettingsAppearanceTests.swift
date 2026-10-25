import AppKit
import Browser
import TestSupport
import Testing

@testable import Interface

/// A view stands in for the app: setting `NSApp.appearance` in a test would change it for every
/// test running beside it.
@MainActor @Test func theAppearanceSettingIsAppliedAtOnceAndAfterEachChange() throws {
    let folder = try TemporaryFolder("SettingsAppearanceTests")
    let settings = storedSettings(in: folder)
    settings.appearance = .dark
    let view = NSView()

    settings.applyAppearance(to: view)
    #expect(view.appearance?.name == .darkAqua)
    #expect(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)

    settings.appearance = .light
    #expect(view.appearance?.name == .aqua)
    #expect(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)

    settings.appearance = .auto
    #expect(view.appearance == nil)
}
