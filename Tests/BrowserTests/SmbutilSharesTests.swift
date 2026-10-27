import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let dylans = ShareRequest(server: testServer, user: "dylan")

/// An executable shell script in `folder` that runs `body`, standing in for `smbutil`.
private func script(_ body: String, in folder: TemporaryFolder) throws -> URL {
    let url = folder.url.appending(path: "smbutil-\(UUID().uuidString)")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// Starts `runner` for `request` on a `BlockingCallThread`, as `ServerShares` does.
private func launch(_ runner: SmbutilShares, _ request: ShareRequest = dylans)
    async throws(ShareListError) -> SmbutilRun
{
    try await BlockingCallThread.run { () throws(ShareListError) in try runner.launch(request) }
}

/// What `run` ends with, waited for on a `BlockingCallThread`.
private func end(of run: SmbutilRun) async -> Result<ShareList, ShareListError> {
    await BlockingCallThread.run { run.wait() }
}

/// Lists with a script running `body` in place of `smbutil`.
private func list(running body: String) async throws -> Result<ShareList, ShareListError> {
    let folder = try TemporaryFolder("SmbutilSharesTests")
    let run = try await launch(SmbutilShares(executable: try script(body, in: folder)))
    return await end(of: run)
}

/// Whether a process with `pid` exists, a zombie included.
private func exists(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
}

@Test(arguments: [
    (ShareRequest(server: testServer, user: "dylan"), "//dylan@HAL9000._smb._tcp.local"),
    (ShareRequest(server: testServer, user: nil), "//HAL9000._smb._tcp.local"),
    (
        ShareRequest(server: testServer, user: "DOMAIN;dyl an"),
        "//DOMAIN;dyl%20an@HAL9000._smb._tcp.local"
    ),
    (
        ShareRequest(server: testServer, user: "dyl@an:x/%"),
        "//dyl%40an%3Ax%2F%25@HAL9000._smb._tcp.local"
    ),
    (ShareRequest(server: Server(host: "HAL\\0329000")!, user: "dylan"), "//dylan@HAL\\0329000"),
    (ShareRequest(server: Server(host: "fe80::1%en0")!, user: "dylan"), "//dylan@[fe80::1%en0]"),
    (ShareRequest(server: Server(host: "2001:db8::1")!, user: nil), "//[2001:db8::1]"),
])
func theCommandNamesTheUserEncodedOnceAndTheHostAsWritten(request: ShareRequest, url: String) {
    #expect(SmbutilShares.arguments(for: request) == ["view", "-N", url])
}

@Test func theToolRunsWithTheArgumentsAndAUTF8Locale() async throws {
    let result = try await list(running: #"echo "$LC_ALL $*" >&2; exit 5"#)
    #expect(result == .failure(.failed("en_US.UTF-8 view -N //dylan@HAL9000._smb._tcp.local")))
}

@Test func theListIsParsedFromWhatTheToolPrints() async throws {
    let printed =
        #"printf 'Share%43sType    Comments\n-------------------------------\n'"#
        + #"; printf 'main%44sDisk    \n\n1 shares listed\n'"#
    #expect(try await list(running: printed) == .success(["main"]))
}

@Test func exit77IsARejectedPassword() async throws {
    let result = try await list(
        running: "echo 'smbutil: server rejected the authentication' >&2; exit 77")
    #expect(result == .failure(.rejected))
}

@Test func anotherExitFailsWithTheFirstLineOfItsErrors() async throws {
    let result = try await list(running: "printf 'first line\\nsecond line\\n' >&2; exit 3")
    #expect(result == .failure(.failed("first line")))
    let silent = try await list(running: "exit 3")
    #expect(silent == .failure(.failed("smbutil exited with status 3")))
}

@Test func moreThanAMegabyteOfOutputIsUnparsable() async throws {
    let result = try await list(running: "head -c 1048577 /dev/zero")
    #expect(result == .failure(.unparsable))
}

@Test func aMissingToolIsToolMissing() async throws {
    let folder = try TemporaryFolder("SmbutilSharesTests")
    let runner = SmbutilShares(executable: folder.url.appending(path: "no-such-smbutil"))
    await #expect(throws: ShareListError.toolMissing) { try await launch(runner) }
}

@Test func aToolThatFillsBothPipesAndHangsEndsWhenTerminatedAndIsReaped() async throws {
    let folder = try TemporaryFolder("SmbutilSharesTests")
    let body = """
        head -c 300000 /dev/zero
        head -c 300000 /dev/zero >&2
        exec sleep 600
        """
    let run = try await launch(SmbutilShares(executable: try script(body, in: folder)))
    // Both pipes hold far more than their buffers, so this ends only if both are drained.
    await settle { run.bytesRead == (output: 300_000, errors: 300_000) }
    #expect(exists(run.pid))

    run.terminate()
    #expect(await end(of: run) == .failure(.unreachable))
    #expect(!exists(run.pid))
}

@Test func aToolThatIgnoresTerminationIsKilledTwoSecondsLater() async throws {
    let folder = try TemporaryFolder("SmbutilSharesTests")
    let clock = ManualClock()
    let body = """
        trap '' TERM
        echo ready
        exec sleep 600
        """
    let run = try await launch(
        SmbutilShares(executable: try script(body, in: folder), clock: clock))
    await settle { run.bytesRead.output == 6 }

    run.terminate()
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: SmbutilShares.killDelay - .milliseconds(1))
    #expect(exists(run.pid))
    clock.advance(by: .milliseconds(1))
    #expect(await end(of: run) == .failure(.unreachable))
    #expect(!exists(run.pid))
}
