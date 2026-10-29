import AppKit
import BrowserTestSupport
import ServiceManagement
import Testing

@testable import Interface

/// A login item that records what was asked of it and never reaches the system's.
@MainActor
final class StubLoginItem: LoginItem {
    var status: SMAppService.Status
    var isAvailable: Bool
    /// What the next register or unregister throws, once.
    var failure: (any Error)?
    /// What register or unregister leaves the status as, when it succeeds.
    var statusAfterRegister: SMAppService.Status = .enabled
    private(set) var calls: [String] = []

    init(_ status: SMAppService.Status = .notRegistered, isAvailable: Bool = true) {
        self.status = status
        self.isAvailable = isAvailable
    }

    func register() throws {
        calls.append("register")
        try throwFailure()
        status = statusAfterRegister
    }

    func unregister() throws {
        calls.append("unregister")
        try throwFailure()
        status = .notRegistered
    }

    func openSystemSettings() {
        calls.append("openSystemSettings")
    }

    private func throwFailure() throws {
        if let failure {
            self.failure = nil
            throw failure
        }
    }
}

/// A file viewer setting that records what was asked of it and never reaches the global
/// `NSFileViewer` key.
@MainActor
final class StubFileViewerSetting: FileViewerSetting {
    nonisolated static let searcher = "com.dylanfisher.searcher"
    nonisolated static let pathFinder = "com.cocoatech.PathFinder"

    var searcherID: String?
    var viewer: String?
    /// The installed apps' names by bundle ID.
    var apps = [searcher: "Searcher", pathFinder: "Path Finder"]
    /// Whether the next write fails, once.
    var failsNextWrite = false
    private(set) var writes: [String?] = []

    init(_ viewer: String? = nil, searcherID: String? = searcher) {
        self.viewer = viewer
        self.searcherID = searcherID
    }

    func setViewer(_ id: String?) throws {
        writes.append(id)
        if failsNextWrite {
            failsNextWrite = false
            throw FileViewerWriteFailed()
        }
        viewer = id
    }

    func appName(of id: String) -> String? { apps[id] }
}

/// A model over `loginItem` and `fileViewer` that records what it would announce instead of
/// posting it.
@MainActor
private func general(
    _ loginItem: StubLoginItem = StubLoginItem(),
    fileViewer: StubFileViewerSetting = StubFileViewerSetting()
) -> (GeneralSettings, () -> [String]) {
    let model = GeneralSettings(
        loginItem: loginItem, fileViewer: fileViewer, settings: untouchedSettings(),
        systemActions: StubSystemActions())
    var announced: [String] = []
    model.postAccessibility = { _, notification, userInfo in
        #expect(notification == .announcementRequested)
        announced.append(userInfo?[.announcement] as? String ?? "")
    }
    return (model, { announced })
}

/// The checkbox shows the system's status: on while registered, waiting for approval included,
/// and off when the system has no record of Searcher.
@MainActor @Test func theCheckboxShowsTheSystemsStatus() {
    let expected: [(SMAppService.Status, Bool, String?)] = [
        (.enabled, true, nil),
        (.notRegistered, false, nil),
        (.requiresApproval, true, GeneralSettings.approvalNote),
        (.notFound, false, nil),
    ]
    for (status, isOn, note) in expected {
        let (model, _) = general(StubLoginItem(status))
        #expect(model.opensAtLogin == isOn, "\(status)")
        #expect(model.loginItemNote == note, "\(status)")
        #expect(model.needsApproval == (status == .requiresApproval), "\(status)")
        #expect(model.canChangeOpensAtLogin, "\(status)")
    }
}

/// The status is read again on refresh, so a change made in System Settings shows.
@MainActor @Test func refreshReadsTheStatusAgain() {
    let loginItem = StubLoginItem(.enabled)
    let (model, _) = general(loginItem)
    #expect(model.opensAtLogin)

    loginItem.status = .notRegistered
    #expect(model.opensAtLogin)
    model.refreshLoginItem()

    #expect(!model.opensAtLogin)
}

@MainActor @Test func checkingRegistersAndUncheckingUnregisters() {
    let loginItem = StubLoginItem()
    let (model, announced) = general(loginItem)

    model.setOpensAtLogin(true)
    #expect(loginItem.calls == ["register"])
    #expect(model.opensAtLogin)

    model.setOpensAtLogin(false)
    #expect(loginItem.calls == ["register", "unregister"])
    #expect(!model.opensAtLogin)
    #expect(model.loginItemProblem == nil)
    #expect(announced().isEmpty)
}

/// A register that leaves the item waiting for approval says so, and its button opens System
/// Settings at Login Items.
@MainActor @Test func approvalOpensLoginItemsSettings() {
    let loginItem = StubLoginItem()
    loginItem.statusAfterRegister = .requiresApproval
    let (model, _) = general(loginItem)

    model.setOpensAtLogin(true)
    #expect(model.opensAtLogin)
    #expect(model.needsApproval)
    model.openLoginItemsSettings()

    #expect(loginItem.calls == ["register", "openSystemSettings"])
}

/// A refused change shows why, is read out, leaves the checkbox at the system's status, and
/// stays until OK.
@MainActor @Test func aFailedChangeShowsItsError() {
    let loginItem = StubLoginItem()
    let reason = "Operation not permitted"
    loginItem.failure = NSError(
        domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    let (model, announced) = general(loginItem)

    model.setOpensAtLogin(true)

    let problem = model.loginItemProblem
    #expect(problem == "Searcher couldn't be added to the login items: \(reason)")
    #expect(announced() == [problem ?? ""])
    #expect(!model.opensAtLogin)

    model.refreshLoginItem()
    #expect(model.loginItemProblem == problem)
    model.dismissLoginItemProblem()
    #expect(model.loginItemProblem == nil)

    loginItem.status = .enabled
    model.refreshLoginItem()
    loginItem.failure = NSError(
        domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    model.setOpensAtLogin(false)
    #expect(
        model.loginItemProblem == "Searcher couldn't be removed from the login items: \(reason)")
    #expect(model.opensAtLogin)
}

/// Run outside its app bundle, Searcher can't be a login item: the checkbox is off and
/// disabled, and says why.
@MainActor @Test func outsideTheAppBundleTheCheckboxIsOff() {
    let (model, _) = general(StubLoginItem(.notFound, isAvailable: false))

    #expect(!model.opensAtLogin)
    #expect(!model.canChangeOpensAtLogin)
    #expect(model.loginItemNote == GeneralSettings.unavailableNote)
}

// MARK: File viewer

/// The checkbox, its note and Use Default follow what the global key names: nothing, Searcher,
/// another installed app, or an app that isn't installed.
@MainActor @Test func theFileViewerCheckboxShowsTheGlobalKey() {
    let missing = "com.example.gone"
    let expected: [(String?, Bool, String?, Bool)] = [
        (nil, false, nil, false),
        (StubFileViewerSetting.searcher, true, nil, true),
        (
            StubFileViewerSetting.pathFinder, false,
            "Other apps' Show in Finder opens Path Finder.", true
        ),
        (
            missing, false,
            "Other apps' Show in Finder names \u{201C}\(missing)\u{201D}, which isn't installed,"
                + " so Finder shows files.", true
        ),
    ]
    for (viewer, isOn, note, canUseDefault) in expected {
        let (model, _) = general(fileViewer: StubFileViewerSetting(viewer))
        let key = String(describing: viewer)
        #expect(model.showsFilesInSearcher == isOn, "\(key)")
        #expect(model.fileViewerNote == note, "\(key)")
        #expect(model.canUseDefaultFileViewer == canUseDefault, "\(key)")
        #expect(model.canChangeFileViewer, "\(key)")
    }
}

/// Checking writes Searcher's ID, unchecking removes it, and Use Default removes whatever the
/// key names.
@MainActor @Test func checkingAndUncheckingWriteTheGlobalKey() {
    let fileViewer = StubFileViewerSetting()
    let (model, announced) = general(fileViewer: fileViewer)

    model.setShowsFilesInSearcher(true)
    #expect(fileViewer.writes == [StubFileViewerSetting.searcher])
    #expect(model.showsFilesInSearcher)
    #expect(model.canUseDefaultFileViewer)

    model.setShowsFilesInSearcher(false)
    #expect(fileViewer.writes == [StubFileViewerSetting.searcher, nil])
    #expect(!model.showsFilesInSearcher)
    #expect(!model.canUseDefaultFileViewer)

    fileViewer.viewer = StubFileViewerSetting.pathFinder
    model.refreshFileViewer()
    model.useDefaultFileViewer()
    #expect(fileViewer.writes == [StubFileViewerSetting.searcher, nil, nil])
    #expect(fileViewer.viewer == nil)
    #expect(model.fileViewerNote == nil)
    #expect(!model.canUseDefaultFileViewer)
    #expect(model.fileViewerProblem == nil)
    #expect(announced().isEmpty)
}

/// Unchecking after another app took the key over, while the pane still showed Searcher's,
/// leaves the other app's ID in place.
@MainActor @Test func uncheckingKeepsAnotherAppsID() {
    let fileViewer = StubFileViewerSetting(StubFileViewerSetting.searcher)
    let (model, _) = general(fileViewer: fileViewer)
    #expect(model.showsFilesInSearcher)

    fileViewer.viewer = StubFileViewerSetting.pathFinder
    model.setShowsFilesInSearcher(false)

    #expect(fileViewer.writes.isEmpty)
    #expect(fileViewer.viewer == StubFileViewerSetting.pathFinder)
    #expect(model.fileViewerNote == "Other apps' Show in Finder opens Path Finder.")
}

/// A write macOS didn't save shows why, is read out, and stays until OK.
@MainActor @Test func aFailedFileViewerWriteShowsItsError() {
    let fileViewer = StubFileViewerSetting()
    fileViewer.failsNextWrite = true
    let (model, announced) = general(fileViewer: fileViewer)

    model.setShowsFilesInSearcher(true)

    let problem = model.fileViewerProblem
    #expect(problem == "The file viewer couldn't be changed: \(FileViewerWriteFailed.reason)")
    #expect(announced() == [problem ?? ""])
    #expect(!model.showsFilesInSearcher)
    model.refreshFileViewer()
    #expect(model.fileViewerProblem == problem)
    model.dismissFileViewerProblem()
    #expect(model.fileViewerProblem == nil)

    fileViewer.viewer = StubFileViewerSetting.pathFinder
    model.refreshFileViewer()
    fileViewer.failsNextWrite = true
    model.useDefaultFileViewer()
    #expect(model.fileViewerProblem == problem)
    #expect(model.canUseDefaultFileViewer)
}

/// Run outside its app bundle, Searcher can't be the file viewer: the checkbox is off and
/// disabled and says why, and Use Default still removes another app's ID.
@MainActor @Test func outsideTheAppBundleOnlyUseDefaultWorks() {
    let fileViewer = StubFileViewerSetting(StubFileViewerSetting.pathFinder, searcherID: nil)
    let (model, _) = general(fileViewer: fileViewer)

    #expect(!model.showsFilesInSearcher)
    #expect(!model.canChangeFileViewer)
    #expect(model.fileViewerNote == GeneralSettings.fileViewerUnavailableNote)
    #expect(model.canUseDefaultFileViewer)

    model.useDefaultFileViewer()
    #expect(fileViewer.writes == [nil])
    #expect(!model.canUseDefaultFileViewer)
}

/// The key is read again on refresh, so a change made by `defaults` or another app shows.
@MainActor @Test func refreshReadsTheFileViewerAgain() {
    let fileViewer = StubFileViewerSetting()
    let (model, _) = general(fileViewer: fileViewer)
    #expect(!model.showsFilesInSearcher)

    fileViewer.viewer = StubFileViewerSetting.searcher
    #expect(!model.showsFilesInSearcher)
    model.refreshFileViewer()

    #expect(model.showsFilesInSearcher)
}

/// Searcher's own reveals go to Finder: the argument domain names Finder as the file viewer,
/// and keeps what it held.
@Test func finderJoinsTheArgumentDomain() {
    let merged = GlobalFileViewerSetting.keepingRevealsInFinder([
        "Other": 1, "NSFileViewer": StubFileViewerSetting.searcher,
    ])

    #expect(merged.count == 2)
    #expect(merged["Other"] as? Int == 1)
    #expect(merged["NSFileViewer"] as? String == "com.apple.finder")
}
