import Base
import Darwin
import Foundation
import TestSupport
import Testing

@Test func aResolvedPathFollowsLinksAndDropsDots() throws {
    let folder = try TemporaryFolder("ResolvedPathTests")
    let target = folder.url.appending(path: "Ünïcødé 📁").path
    try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
    let link = folder.url.appending(path: "link").path
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

    #expect(resolvedPath(link) == target)
    #expect(resolvedPath(link + "/../link/.") == target)
}

@Test func theRootResolvesToItself() {
    #expect(resolvedPath("/") == "/")
}

@Test func aMissingItemHasNoResolvedPathAndErrnoSaysWhy() throws {
    let folder = try TemporaryFolder("ResolvedPathTests")

    let resolved = resolvedPath(folder.url.appending(path: "missing").path)
    let code = errno

    #expect(resolved == nil)
    #expect(code == ENOENT)
}

@Test func anEmptyPathHasNoResolvedPath() {
    #expect(resolvedPath("") == nil)
}
