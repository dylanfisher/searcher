import Base
import Darwin
import Foundation

/// Lists a server's shares as a user sees them. `ServerShares` runs one; tests pass a gated one.
public protocol ShareEnumerator: Sendable {
    /// Starts listing `request`'s shares and returns the run. It can block, so it is called on a
    /// `BlockingCallThread`.
    func start(_ request: ShareRequest) throws(ShareListError) -> any ShareEnumeration
}

/// One run of a `ShareEnumerator`.
public protocol ShareEnumeration: Sendable {
    /// Blocks until the run has ended, and returns the disk shares it listed. Called once, on a
    /// `BlockingCallThread`.
    func wait() -> Result<[String], ShareListError>
    /// Ends the run early, after which `wait` returns soon. Safe from any thread, any number of
    /// times.
    func terminate()
}

/// Lists a server's shares with `smbutil view -N`, which reuses the session a mounted share
/// holds and never prompts. The tool runs with no shell, its output in UTF-8, and is always
/// waited for, so it is reaped and never left a zombie (docs/decisions/0115-server-shares.md).
public struct SmbutilShares: ShareEnumerator {
    /// Where the system installs `smbutil`.
    public static let tool = URL(fileURLWithPath: "/usr/bin/smbutil")
    /// How long a run has after `terminate()` to end before it is killed.
    public static let killDelay: Duration = .seconds(2)
    /// The most output a run keeps; more is `unparsable`. Eight shares take 600 bytes.
    static let outputCap = 1 << 20

    private let executable: URL
    /// Starts a wait of the given length on the clock, taking the deadline at once, and returns
    /// the wait.
    private let startWait: @Sendable (Duration) -> @Sendable () async throws -> Void

    /// A runner of `executable`, `smbutil` unless a test passes a script, that kills a run
    /// `killDelay` after its termination on `clock`.
    public init<C: Clock<Duration>>(executable: URL = tool, clock: C = ContinuousClock()) {
        self.executable = executable
        startWait = { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
    }

    /// `smbutil`'s arguments for `request`: `view -N //[user@]host`, the user percent-encoded
    /// once for a URL's user part (`;` kept, `:` encoded), the host as its share's source writes
    /// it, an IPv6 address in brackets.
    public static func arguments(for request: ShareRequest) -> [String] {
        var target = "//"
        if let user = request.user {
            // A URL's user part, less `:`, which `smbutil` reads as the start of a password.
            let allowed = CharacterSet.urlUserAllowed.subtracting(CharacterSet(charactersIn: ":"))
            guard let encoded = user.addingPercentEncoding(withAllowedCharacters: allowed) else {
                preconditionFailure("the user \(user) has no percent-encoding")
            }
            target += encoded + "@"
        }
        let host = request.server.host
        // Only an IPv6 address holds a `:` (`Server.init(host:)`); it needs its brackets back.
        return ["view", "-N", target + (host.contains(":") ? "[\(host)]" : host)]
    }

    public func start(_ request: ShareRequest) throws(ShareListError) -> any ShareEnumeration {
        try launch(request)
    }

    /// Starts `smbutil` for `request`. A missing tool throws `toolMissing`.
    func launch(_ request: ShareRequest) throws(ShareListError) -> SmbutilRun {
        BlockingCallThread.requireCurrent()
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(for: request)
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let run = SmbutilRun(process: process, startWait: startWait)
        do {
            try process.run()
        } catch {
            // The handler holds the run, which holds the process: let go of it.
            process.terminationHandler = nil
            if let error = error as? CocoaError, error.code == .fileNoSuchFile {
                throw .toolMissing
            }
            throw .failed("\(executable.path) didn't start: \(error.localizedDescription)")
        }
        run.drain(output.fileHandleForReading, isOutput: true)
        run.drain(errors.fileHandleForReading, isOutput: false)
        return run
    }
}

/// One `smbutil` process. Its stdout and stderr are each drained on a thread of their own, since
/// a full pipe would stall it; its end is waited for with a semaphore its termination handler
/// signals, not `waitUntilExit`, which runs the run loop.
final class SmbutilRun: ShareEnumeration, @unchecked Sendable {
    private let process: Process
    private let startWait: @Sendable (Duration) -> @Sendable () async throws -> Void
    /// Signalled once the process has exited and been reaped.
    private let exitedSignal = DispatchSemaphore(value: 0)
    /// Signalled once per pipe drained to its end.
    private let drainedSignal = DispatchSemaphore(value: 0)

    // `lock` guards everything below.
    private let lock = NSLock()
    private var output = Data()
    private var errors = Data()
    private var counts = (output: 0, errors: 0)
    private var readFailure: String?
    private var exited = false
    private var terminated = false

    init(
        process: Process,
        startWait: @escaping @Sendable (Duration) -> @Sendable () async throws -> Void
    ) {
        self.process = process
        self.startWait = startWait
        process.terminationHandler = { process in
            // The handler holds the run, which holds the process: let go of it.
            process.terminationHandler = nil
            self.lock.withLock { self.exited = true }
            self.exitedSignal.signal()
        }
    }

    /// The process's id, once it has started.
    var pid: pid_t { process.processIdentifier }

    /// The bytes read so far from stdout and from stderr.
    var bytesRead: (output: Int, errors: Int) {
        lock.withLock { counts }
    }

    /// Reads `handle` to its end on a thread of its own. Stdout keeps at most
    /// `SmbutilShares.outputCap` bytes, and stderr as much; the rest is read and dropped.
    func drain(_ handle: FileHandle, isOutput: Bool) {
        BlockingCallThread.start { [self] in
            defer { drainedSignal.signal() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                // `read(2)`, not `FileHandle.read(upToCount:)`, which waits for a full buffer.
                let count = buffer.withUnsafeMutableBytes {
                    read(handle.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR { continue }
                if count < 0 {
                    let code = errno
                    lock.withLock {
                        readFailure =
                            "reading smbutil's output failed: \(String(cString: strerror(code)))"
                    }
                    return
                }
                if count == 0 { return }
                let chunk = Data(buffer[..<count])
                lock.withLock {
                    if isOutput {
                        counts.output += chunk.count
                        if output.count <= SmbutilShares.outputCap { output.append(chunk) }
                    } else {
                        counts.errors += chunk.count
                        if errors.count <= SmbutilShares.outputCap { errors.append(chunk) }
                    }
                }
            }
        }
    }

    func wait() -> Result<[String], ShareListError> {
        BlockingCallThread.requireCurrent()
        exitedSignal.wait()
        drainedSignal.wait()
        drainedSignal.wait()
        let (output, errors, outputCount, readFailure) = lock.withLock {
            (self.output, self.errors, counts.output, self.readFailure)
        }
        if let readFailure { return .failure(.failed(readFailure)) }
        if process.terminationReason == .uncaughtSignal { return .failure(.unreachable) }
        switch process.terminationStatus {
        case 0:
            guard outputCount <= SmbutilShares.outputCap else { return .failure(.unparsable) }
            return Result { () throws(ShareListError) in try ShareNames.parse(output) }
        case 77:
            return .failure(.rejected)
        case let status:
            let firstLine = String(decoding: errors, as: UTF8.self)
                .split(separator: "\n").first.map(String.init)
            return .failure(.failed(firstLine ?? "smbutil exited with status \(status)"))
        }
    }

    /// Sends the process `SIGTERM`, and `SIGKILL` if it is still running `killDelay` later.
    func terminate() {
        let first = lock.withLock {
            guard !exited, !terminated else { return false }
            terminated = true
            process.terminate()
            return true
        }
        guard first else { return }
        let wait = startWait(SmbutilShares.killDelay)
        Task { [self] in
            do {
                try await wait()
            } catch {
                preconditionFailure("the clock failed a wait with \(error)")
            }
            lock.withLock {
                guard !exited else { return }
                kill(pid, SIGKILL)
            }
        }
    }
}
