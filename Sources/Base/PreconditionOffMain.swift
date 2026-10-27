import Foundation

/// Traps on the main thread, naming `who` as doing file-system I/O, which blocks on a share
/// that has stopped answering. The trap reports the caller's file and line.
public func preconditionOffMain(
    _ who: String, file: StaticString = #fileID, line: UInt = #line
) {
    precondition(
        !Thread.isMainThread, "\(who) does file-system I/O; call it off the main thread",
        file: file, line: line)
}
