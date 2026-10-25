import AppKit
import Testing

// Fails the run when a window is left on the main display while a second display exists. A
// run-loop observer installed when the test bundle loads checks every pass, so tests get it
// without opting in. A window ordered in and out again without a pass of the run loop between
// goes unseen. Why: docs/decisions/0091-test-windows-on-second-display.md.

public enum WindowGuard {
    /// What each visible window of `windows` on the main display is, as "Class \"title\"". Empty
    /// when only one display is attached.
    @MainActor public static func offenders(
        in windows: [NSWindow] = NSApp.windows, screens: [CGRect] = NSScreen.screens.map(\.frame)
    ) -> [String] {
        guard screens.count > 1 else { return [] }
        return windows.filter { $0.isVisible && $0.frame.intersects(screens[0]) }
            .map { "\(type(of: $0)) \"\($0.title)\"" }
    }

    /// Records an issue naming each offender.
    @MainActor public static func check(
        _ windows: [NSWindow] = NSApp.windows, screens: [CGRect] = NSScreen.screens.map(\.frame)
    ) {
        let found = offenders(in: windows, screens: screens)
        guard !found.isEmpty else { return }
        // The location is spelled out because the default one is a macro, which a plain
        // `swift build` can't expand without the testing plugin.
        Issue.record(
            "a test left a window on the main display: \(found.joined(separator: ", ")). Show it with SecondDisplay.orderFront.",
            sourceLocation: SourceLocation(
                fileID: #fileID, filePath: #filePath, line: #line, column: #column))
    }
}

private func installWindowGuard() {
    let observer = CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
    ) { _, _ in
        // Test processes that never start an application have no windows to check.
        MainActor.assumeIsolated {
            if let app = NSApp as NSApplication? { WindowGuard.check(app.windows) }
        }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
}

/// Installs the observer when the test bundle loads, before any test runs.
@used @section("__DATA,__mod_init_func")
private let installWindowGuardAtLoad: @convention(c) () -> Void = installWindowGuard
