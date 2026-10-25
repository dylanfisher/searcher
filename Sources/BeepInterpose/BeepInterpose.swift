import AppKit
import AudioToolbox

// Replaces the calls every alert sound ends in, so a test run never plays one. dyld applies the
// `__interpose` section only to a dylib loaded at launch, which is why this is a dylib that
// `scripts/test` inserts and not part of the test bundle. The replacements call the reporter that
// TestSupport registers, which fails the running test.

typealias Reporter = @convention(c) (UnsafePointer<CChar>) -> Void
typealias Completion = @convention(block) () -> Void
typealias Silent = @convention(c) () -> Void
typealias SilentSound = @convention(c) (UInt32) -> Void
typealias SilentSoundWithCompletion = @convention(c) (UInt32, Completion?) -> Void

nonisolated(unsafe) private var reporter: Reporter?

@_cdecl("searcher_beep_set_reporter")
public func setReporter(_ newReporter: @escaping @convention(c) (UnsafePointer<CChar>) -> Void) {
    reporter = newReporter
}

private func report(_ call: StaticString) {
    call.withUTF8Buffer { name in
        name.withMemoryRebound(to: CChar.self) { chars in
            // Not NUL-terminated, so copy into a C string.
            var bytes = Array(chars)
            bytes.append(0)
            reporter?(bytes)
        }
    }
}

@_extern(c, "NSBeep") private func realBeep()
@_extern(c, "AudioServicesPlayAlertSound") private func realAlertSound(_ id: UInt32)
@_extern(c, "AudioServicesPlayAlertSoundWithCompletion")
private func realAlertSoundWithCompletion(_ id: UInt32, _ done: Completion?)

@_cdecl("searcher_beep_silent_beep")
func silentBeep() { report("NSBeep") }

@_cdecl("searcher_beep_silent_alert")
func silentAlertSound(_ id: UInt32) { report("AudioServicesPlayAlertSound") }

@_cdecl("searcher_beep_silent_alert_with_completion")
func silentAlertSoundWithCompletion(_ id: UInt32, _ done: Completion?) {
    report("AudioServicesPlayAlertSoundWithCompletion")
    done?()
}

// Stray stops of the main run loop. Once a test has pulled events with `NSApp.nextEvent` (a real
// press does), HIToolbox queues blocks on the main run loop, at any time after, that each stop
// it, to wake a `nextEvent` that is no longer waiting. They run in the outermost main run loop,
// the one that keeps the Swift Testing runner alive, and the process then exits normally with
// exit status 0 and no summary. After a test calls `searcher_runloop_stops_drop`, the replacement
// drops every stop of the main run loop except the Swift runtime's own, which ends the run.
nonisolated(unsafe) private var dropsStops = false
nonisolated(unsafe) private var droppedStops = 0

typealias Stop = @convention(c) (UnsafeRawPointer?) -> Void

@_extern(c, "CFRunLoopStop") private func realStop(_ loop: UnsafeRawPointer?)

/// Starts dropping the main run loop's stray stops, for the rest of the process.
@_cdecl("searcher_runloop_stops_drop")
public func dropStops() {
    dropsStops = true
}

/// How many stops have been dropped.
@_cdecl("searcher_runloop_stops_dropped")
public func countDroppedStops() -> Int {
    droppedStops
}

@_cdecl("searcher_runloop_stop")
func silentStop(_ loop: UnsafeRawPointer?) {
    // Frame 0 is this function, frame 1 the call's entry here, frame 2 its caller.
    if dropsStops,
        loop == UnsafeRawPointer(Unmanaged.passUnretained(CFRunLoopGetMain()).toOpaque()),
        !Thread.callStackSymbols[2].contains("libswift_Concurrency")
    {
        droppedStops += 1
        return
    }
    realStop(loop)
}

@used @section("__DATA,__interpose")
private let interposeStop: (Stop, Stop) = (silentStop, realStop)

@used @section("__DATA,__interpose")
private let interposeBeep: (Silent, Silent) = (silentBeep, realBeep)

@used @section("__DATA,__interpose")
private let interposeAlertSound: (SilentSound, SilentSound) = (silentAlertSound, realAlertSound)

@used @section("__DATA,__interpose")
private let interposeAlertSoundWithCompletion:
    (SilentSoundWithCompletion, SilentSoundWithCompletion) = (
        silentAlertSoundWithCompletion, realAlertSoundWithCompletion
    )
