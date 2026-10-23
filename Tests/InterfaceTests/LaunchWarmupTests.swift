import AppKit
import CoreText
import Testing
import os

@testable import Interface

/// A window that is never shown, with its content waiting to be drawn, as a new window's is.
@MainActor private func unshownWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
        backing: .buffered, defer: false)
    window.contentView?.needsDisplay = true
    return window
}

/// Runs the main run loop through at least one pass that ends by waiting. AppKit lays out and
/// draws a window in such a pass even when it isn't on screen.
@MainActor private func runOnePass() {
    CFRunLoopRunInMode(.defaultMode, 0.02, false)
}

/// Runs passes, letting the main actor's waiting tasks run between them, until `condition` holds
/// or 100 passes have run.
@MainActor private func runPasses(until condition: () -> Bool) async {
    for _ in 0..<100 where !condition() {
        runOnePass()
        await Task.yield()
    }
}

@MainActor @Suite(.serialized) struct LaunchWarmupTests {
    @Test func runsAfterTheFirstFrameAndNeverBeforeIt() async {
        let window = unshownWindow()
        var pass = 0
        // The first pass leaves the window needing display, as a pass does when AppKit waits for
        // the display's refresh to draw, so the first frame is drawn in the second pass.
        let dirtier = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_500_000
        ) { _, _ in
            pass += 1
            if pass == 1 { MainActor.assumeIsolated { window.contentView?.needsDisplay = true } }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), dirtier, .commonModes)
        defer { CFRunLoopObserverInvalidate(dirtier) }
        var ranInPass: [Int] = []
        var windowWasDrawn: [Bool] = []
        let warmup = LaunchWarmup(work: { window in
            ranInPass.append(pass)
            windowWasDrawn.append(!window.viewsNeedDisplay)
        })

        warmup.start(after: window)
        #expect(ranInPass.isEmpty, "ran before the run loop committed a frame")
        runOnePass()
        await Task.yield()
        // Under load the 20 ms can hold several passes, so the second may already have drawn the
        // frame; the warm-up may only have run if it did.
        #expect(pass >= 2 || ranInPass.isEmpty, "ran after a pass that left the window to draw")
        await runPasses { !ranInPass.isEmpty }
        await warmup.finished()

        #expect(ranInPass.count == 1)
        #expect(ranInPass.allSatisfy { $0 >= 2 }, "\(ranInPass)")
        #expect(windowWasDrawn == [true])
    }

    @Test func doesNothingASecondTime() async {
        let window = unshownWindow()
        var runs = 0
        let warmup = LaunchWarmup(work: { _ in runs += 1 })

        warmup.start(after: window)
        warmup.start(after: window)
        await runPasses { runs > 0 }
        await warmup.finished()
        window.contentView?.needsDisplay = true
        warmup.start(after: unshownWindow())
        warmup.start(after: window)
        for _ in 0..<5 {
            runOnePass()
            await Task.yield()
        }
        await warmup.finished()

        #expect(runs == 1)
    }

    @Test func drawsEverySampleOffTheMainThreadInTheListsFont() async {
        let drawn = OSAllocatedUnfairLock(initialState: [(sample: String, onMain: Bool)]())
        let sizes = OSAllocatedUnfairLock(initialState: Set<CGFloat>())
        let warmup = LaunchWarmup(draw: { sample, font, _ in
            drawn.withLock { $0.append((sample, pthread_main_np() != 0)) }
            let size = CTFontGetSize(font)
            sizes.withLock { _ = $0.insert(size) }
        })
        var done = false

        warmup.start(after: unshownWindow())
        let finishing = Task { @MainActor in
            await warmup.finished()
            done = true
        }
        await runPasses { done }
        await finishing.value

        let calls = drawn.withLock { $0 }
        #expect(calls.map(\.sample) == LaunchWarmup.samples)
        #expect(calls.allSatisfy { !$0.onMain }, "drew on the main thread")
        #expect(sizes.withLock { $0 } == [NSFont.systemFontSize])
    }

    @Test func theAppSharesOneWarmUp() {
        #expect(LaunchWarmup.shared === LaunchWarmup.shared)
    }

    /// The app's own warm-up, not a stand-in.
    @Test func createsNoVisibleWindowAndTakesNoFocus() async {
        let window = unshownWindow()
        let field = NSTextField(labelWithString: "")
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let responder = window.firstResponder
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let visible = NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)
        let key = NSApp.keyWindow
        let main = NSApp.mainWindow
        let active = NSApp.isActive
        let warmup = LaunchWarmup()
        var done = false

        warmup.start(after: window)
        let finishing = Task { @MainActor in
            await warmup.finished()
            done = true
        }
        await runPasses { done }
        await finishing.value

        #expect(Set(NSApp.windows.map(ObjectIdentifier.init)).isSubset(of: windows))
        #expect(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init) == visible)
        #expect(NSApp.keyWindow === key)
        #expect(NSApp.mainWindow === main)
        #expect(NSApp.isActive == active)
        #expect(window.firstResponder === responder)
        #expect(!window.isVisible)
    }
}
