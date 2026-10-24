import AppKit
import TestSupport
import Testing

/// A window that reports itself on screen without being ordered in.
private final class ShownWindow: NSWindow {
    var placement = CGRect.zero
    override var isVisible: Bool { true }
    override var frame: NSRect { placement }
}

@MainActor @Suite struct WindowGuardTests {
    private let main = CGRect(x: 0, y: 0, width: 5120, height: 2880)
    private let side = CGRect(x: 5120, y: 0, width: 5120, height: 2880)

    private func window(at origin: CGPoint) -> ShownWindow {
        let window = ShownWindow(
            contentRect: CGRect(origin: origin, size: CGSize(width: 400, height: 300)),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.placement = CGRect(origin: origin, size: CGSize(width: 400, height: 300))
        window.title = "Fixture"
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aWindowOnTheMainDisplayFailsTheTestAndIsNamed() {
        let shown = window(at: CGPoint(x: 100, y: 100))

        #expect(
            WindowGuard.offenders(in: [shown], screens: [main, side]) == ["ShownWindow \"Fixture\""]
        )
        withKnownIssue("a window on the main display is reported") {
            WindowGuard.check([shown], screens: [main, side])
        }
    }

    @Test func aWindowOnTheSecondDisplayPasses() {
        let shown = window(at: CGPoint(x: 5300, y: 100))

        #expect(WindowGuard.offenders(in: [shown], screens: [main, side]).isEmpty)
    }

    @Test func oneDisplayAllowsTheMainDisplay() {
        let shown = window(at: CGPoint(x: 100, y: 100))

        #expect(WindowGuard.offenders(in: [shown], screens: [main]).isEmpty)
    }

    @Test func aSecondDisplayLeftOfTheMainOneIsNotTheMainOne() {
        let left = CGRect(x: -5120, y: 0, width: 5120, height: 2880)
        let onLeft = window(at: CGPoint(x: -4000, y: 100))
        let onMain = window(at: CGPoint(x: 100, y: 100))

        #expect(WindowGuard.offenders(in: [onLeft], screens: [main, left]).isEmpty)
        #expect(WindowGuard.offenders(in: [onMain], screens: [main, left]).count == 1)
    }
}
