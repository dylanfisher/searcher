import AppKit
import Foundation
import Testing

@testable import Interface

/// The errors a `WorkspaceSystemActions` presented.
@MainActor
private final class ErrorLog {
    var errors: [any Error] = []
}

/// The lookup finds no app, so nothing is opened, and the error is recorded instead of shown.
@MainActor @Test func aBundleIDWithNoInstalledAppFailsWithAnErrorNamingIt() {
    let log = ErrorLog()
    let actions = WorkspaceSystemActions(
        applicationURL: { _ in nil }, presentError: { log.errors.append($0) })

    actions.open(
        URL(fileURLWithPath: "/tmp", isDirectory: true), inAppWithBundleID: "com.example.missing")

    #expect(log.errors.count == 1)
    #expect(log.errors.first?.localizedDescription.contains("com.example.missing") == true)
}
