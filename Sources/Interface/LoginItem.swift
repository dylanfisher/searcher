import Foundation
import ServiceManagement

/// Searcher's entry in the user's login items, which the system keeps: the status is read from
/// it each time, never stored (docs/decisions/0113-open-at-login.md). Tests use a stub, so no
/// test adds the machine's app to its login items.
@MainActor
protocol LoginItem: AnyObject {
    var status: SMAppService.Status { get }
    /// Whether the running app can be a login item at all.
    var isAvailable: Bool { get }
    func register() throws
    func unregister() throws
    /// Opens System Settings ▸ General ▸ Login Items.
    func openSystemSettings()
}

/// The running app as a login item, through `SMAppService.mainApp`.
@MainActor
final class MainAppLoginItem: LoginItem {
    private let service = SMAppService.mainApp

    var status: SMAppService.Status { service.status }

    /// `SMAppService.mainApp` registers the app bundle the process runs from. A bare executable,
    /// as `swift run` starts, has none: the status reads `.notFound` and register fails.
    var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func register() throws { try service.register() }

    func unregister() throws { try service.unregister() }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
