import AppKit
import TestSupport
import Testing

private let main = CGRect(x: 0, y: 25, width: 5120, height: 2815)
private let side = CGRect(x: 5120, y: 0, width: 5120, height: 2840)

@Suite struct SecondDisplayTests {
    @Test func aFrameOnTheMainDisplayMovesToTheSameSpotOnTheSecond() {
        let frame = CGRect(x: 100, y: 300, width: 800, height: 600)

        let moved = SecondDisplay.placed(frame, on: [main, side])

        #expect(moved == CGRect(x: 5220, y: 275, width: 800, height: 600))
        #expect(side.contains(moved))
    }

    @Test func aMovedFrameKeepsItsSizeAndStaysInsideTheSecondDisplay() {
        let tall = CGRect(x: 4800, y: 2500, width: 1000, height: 900)

        let moved = SecondDisplay.placed(tall, on: [main, side])

        #expect(moved.size == tall.size)
        #expect(side.contains(moved))
    }

    @Test func aFrameLargerThanTheSecondDisplayIsShrunkToIt() {
        let huge = CGRect(x: 0, y: 0, width: 9000, height: 4000)

        #expect(SecondDisplay.placed(huge, on: [main, side]) == side)
    }

    @Test func aFrameAlreadyOffTheMainDisplayStaysPut() {
        let frame = CGRect(x: 6000, y: 400, width: 800, height: 600)

        #expect(SecondDisplay.placed(frame, on: [main, side]) == frame)
    }

    @Test func oneDisplayLeavesTheFrameAlone() {
        let frame = CGRect(x: 100, y: 300, width: 800, height: 600)

        #expect(SecondDisplay.placed(frame, on: [main]) == frame)
        #expect(SecondDisplay.placed(frame, on: []) == frame)
    }

    @MainActor @Test func aWindowIsMovedBeforeItIsOrderedIn() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 300, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let displays = NSScreen.screens.map(\.visibleFrame)

        SecondDisplay.move(window)

        if displays.count > 1 {
            #expect(!displays[0].intersects(window.frame))
        } else {
            #expect(window.frame.origin == CGPoint(x: 100, y: 300))
        }
        #expect(!window.isVisible)
    }
}
