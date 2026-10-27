import Foundation

/// Makes the folder at `path` and any folders above it that are missing.
public func makeFolder(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}
