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

/// A model over `loginItem` that records what it would announce instead of posting it.
@MainActor
private func general(_ loginItem: StubLoginItem) -> (GeneralSettings, () -> [String]) {
    let model = GeneralSettings(
        loginItem: loginItem, settings: untouchedSettings(), systemActions: StubSystemActions())
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
