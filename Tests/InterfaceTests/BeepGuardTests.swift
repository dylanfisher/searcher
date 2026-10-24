import AppKit
import Testing

/// The guard in `Sources/TestSupport/BeepGuard.swift` turns a beep into a failed test. If the
/// dylib isn't inserted (a bare `swift test`), no issue is recorded and this test fails.
@MainActor @Test func aBeepFailsTheTestThatMadeIt() {
    withKnownIssue("the alert sound is reported, not played") {
        NSSound.beep()
    }
}
