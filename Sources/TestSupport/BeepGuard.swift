import Foundation
import Testing

// Fails the running test when anything plays the alert sound. The sound itself is replaced in
// Sources/BeepInterpose, which `scripts/test` inserts into the test process; this registers the
// reporter that dylib calls. Why a dylib: docs/decisions/0083-silent-tests.md.

private typealias SetReporter =
    @convention(c) (@convention(c) (UnsafePointer<CChar>) -> Void) -> Void

private func installBeepGuard() {
    guard let found = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "searcher_beep_set_reporter")
    else {
        FileHandle.standardError.write(
            Data("warning: beeps are not guarded; run tests with ./scripts/test\n".utf8))
        return
    }
    unsafeBitCast(found, to: SetReporter.self)({ call in
        // The first frames that aren't the guard or the test runner name the caller; a known
        // issue (BeepGuardTests) prints them too, so keep them short.
        let stack = Thread.callStackSymbols
            .filter { !$0.contains("libBeepInterpose") && !$0.contains("installBeepGuard") }
            .prefix(6).joined(separator: "\n")
        // The location is spelled out because the default one is a macro, which a plain
        // `swift build` (the typecheck step) can't expand without the testing plugin.
        Issue.record(
            "\(String(cString: call)) played the alert sound. Inject a silent `beep`, or send the key to a responder that handles it.\n\(stack)",
            sourceLocation: SourceLocation(
                fileID: #fileID, filePath: #filePath, line: #line, column: #column))
    })
}

/// Registers the reporter when the test bundle loads, before any test runs.
@used @section("__DATA,__mod_init_func")
private let installAtLoad: @convention(c) () -> Void = installBeepGuard
