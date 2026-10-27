import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// What the General pane shows and does: Open at login, which the system's login items hold. The
/// checkbox shows the status last read from them, never a stored copy, and is read again when
/// the window shows and when the app becomes active, so a change made in System Settings shows
/// (docs/decisions/0113-open-at-login.md).
@MainActor @Observable
final class GeneralSettings {
    /// What the pane says while the item waits for the user to allow it in System Settings.
    static let approvalNote =
        "Searcher opens at login once you allow it in System Settings ▸ General ▸ Login Items."
    /// What the pane says when the running app can't be a login item.
    static let unavailableNote =
        "Open at login is available only when Searcher runs from its app bundle."

    @ObservationIgnored private let loginItem: any LoginItem
    private(set) var loginItemStatus: SMAppService.Status
    /// Why the last change to Open at login failed, until OK dismisses it.
    private(set) var loginItemProblem: String?
    /// Posts an accessibility notification. Tests replace it to record what would be posted.
    @ObservationIgnored var postAccessibility:
        @MainActor (
            Any, NSAccessibility.Notification, [NSAccessibility.NotificationUserInfoKey: Any]?
        )
            -> Void = { element, notification, userInfo in
                NSAccessibility.post(
                    element: element, notification: notification, userInfo: userInfo)
            }

    init(loginItem: any LoginItem) {
        self.loginItem = loginItem
        loginItemStatus = loginItem.status
    }

    /// Whether the checkbox is on: registered, or registered and waiting for approval.
    var opensAtLogin: Bool { loginItemStatus == .enabled || needsApproval }

    var needsApproval: Bool { loginItemStatus == .requiresApproval }

    var canChangeOpensAtLogin: Bool { loginItem.isAvailable }

    /// What the pane says under the checkbox, if anything.
    var loginItemNote: String? {
        if !loginItem.isAvailable { return Self.unavailableNote }
        return needsApproval ? Self.approvalNote : nil
    }

    /// Reads the status from the system again.
    func refreshLoginItem() {
        loginItemStatus = loginItem.status
    }

    /// Adds Searcher to the login items or removes it, then reads the status back, which shows
    /// what the system did whether or not the change went through.
    func setOpensAtLogin(_ opens: Bool) {
        defer { refreshLoginItem() }
        do {
            if opens {
                try loginItem.register()
            } else {
                try loginItem.unregister()
            }
            loginItemProblem = nil
        } catch {
            let change = opens ? "added to" : "removed from"
            let problem =
                "Searcher couldn't be \(change) the login items: \(error.localizedDescription)"
            loginItemProblem = problem
            postAccessibility(
                NSApp as Any, .announcementRequested,
                [
                    .announcement: problem,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }

    func dismissLoginItemProblem() {
        loginItemProblem = nil
    }

    func openLoginItemsSettings() {
        loginItem.openSystemSettings()
    }
}

/// The General pane of the Settings window.
struct GeneralSettingsView: View {
    @Bindable var model: GeneralSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Open at login",
                isOn: Binding(
                    get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) })
            )
            .toggleStyle(.checkbox)
            .disabled(!model.canChangeOpensAtLogin)
            if let note = model.loginItemNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if model.needsApproval {
                Button("Open Login Items Settings") { model.openLoginItemsSettings() }
                    .controlSize(.small)
            }
            if let problem = model.loginItemProblem {
                HStack {
                    Text(problem).font(.caption).foregroundStyle(Color.red)
                    Spacer()
                    Button("OK") { model.dismissLoginItemProblem() }.controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
