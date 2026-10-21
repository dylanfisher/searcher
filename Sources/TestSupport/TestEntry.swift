import Base
import Foundation

/// The modified date of every entry `file` and `folder` make: Sep 13, 2020 at 12:26 PM UTC.
public let testDate = Date(timeIntervalSince1970: 1_600_000_000)

/// A regular file modified at `testDate`.
public func file(_ name: String, size: Int64 = 1) -> DirectoryEntry {
    DirectoryEntry(name: name, type: .regular, size: size, modified: testDate)
}

/// A folder modified at `testDate`.
public func folder(_ name: String) -> DirectoryEntry {
    DirectoryEntry(name: name, type: .directory, size: nil, modified: testDate)
}
