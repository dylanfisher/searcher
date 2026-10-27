import Base
import Foundation
import UniformTypeIdentifiers

/// What an entry is, as the Kind column shows it: "Folder", "MP3 audio". Found from the entry's
/// file type and name extension alone, so finding it reads no file.
public struct EntryKind: Hashable, Sendable {
    /// The type the kind was found from, for looking up its icon.
    public let type: UTType
    /// The type's description with its first letter capitalized, as Finder shows kinds.
    public let text: String
    /// Whether the type is text, such as plain text, source code or JSON, which shows its type
    /// icon rather than a thumbnail of a page of text, as Finder shows it. An image stored as
    /// text, such as SVG, isn't.
    public let isText: Bool

    /// The kind of an entry of `fileType` whose name ends in `pathExtension`. Each pair is looked
    /// up once per process and each type described once. Call it off the main thread: a lookup
    /// the cache misses asks Launch Services.
    ///
    /// A file whose extension has no described type is `.data`, a folder is `.folder`, and a
    /// package whose extension isn't a described package type, as one with the bundle bit can
    /// be, is `.package`.
    public init(_ fileType: DirectoryEntry.FileType, pathExtension: Substring) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        self = Self.cache.kind(fileType, pathExtension: pathExtension)
    }

    private init(type: UTType, text: String) {
        self.type = type
        self.text = text
        isText = type.conforms(to: .text) && !type.conforms(to: .image)
    }

    private static let cache = Cache()

    /// How many times the type of `fileType` and `pathExtension` has been looked up, for tests
    /// that check the cache.
    static func typeLookupCount(_ fileType: DirectoryEntry.FileType, pathExtension: String) -> Int {
        cache.typeLookupCount(fileType, pathExtension: pathExtension)
    }

    /// How many times `type` has been described, for tests that check the cache.
    static func descriptionCount(of type: UTType) -> Int {
        cache.descriptionCount(of: type)
    }

    /// Kinds by file type and extension, and by type, shared by every listing in the process.
    private final class Cache: @unchecked Sendable {
        private struct Key: Hashable {
            let fileType: DirectoryEntry.FileType
            let pathExtension: Substring
        }

        private let lock = NSLock()
        private var byExtension: [Key: EntryKind] = [:]
        private var byType: [UTType: EntryKind] = [:]
        private var typeLookups: [Key: Int] = [:]
        private var descriptions: [UTType: Int] = [:]

        func kind(_ fileType: DirectoryEntry.FileType, pathExtension: Substring) -> EntryKind {
            lock.lock()
            defer { lock.unlock() }
            // A new Substring, so the key doesn't keep the caller's whole name alive.
            let key = Key(fileType: fileType, pathExtension: Substring(String(pathExtension)))
            if let kind = byExtension[key] {
                return kind
            }
            let type = Self.type(fileType, pathExtension: String(pathExtension))
            typeLookups[key, default: 0] += 1
            let kind: EntryKind
            if let known = byType[type] {
                kind = known
            } else {
                kind = Self.described(type)
                descriptions[type, default: 0] += 1
                byType[type] = kind
            }
            byExtension[key] = kind
            return kind
        }

        func typeLookupCount(_ fileType: DirectoryEntry.FileType, pathExtension: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return typeLookups[Key(fileType: fileType, pathExtension: Substring(pathExtension))]
                ?? 0
        }

        func descriptionCount(of type: UTType) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return descriptions[type] ?? 0
        }

        private static func type(_ fileType: DirectoryEntry.FileType, pathExtension: String)
            -> UTType
        {
            switch fileType {
            case .regular:
                if let type = UTType(filenameExtension: pathExtension, conformingTo: .data),
                    type.localizedDescription != nil
                {
                    return type
                }
                return .data
            case .directory:
                return .folder
            case .package:
                if let type = UTType(filenameExtension: pathExtension, conformingTo: .directory),
                    type.conforms(to: .package), type.localizedDescription != nil
                {
                    return type
                }
                return .package
            case .symbolicLink:
                return .symbolicLink
            case .other:
                return .item
            case .unmountedShare:
                return .volume
            }
        }

        private static func described(_ type: UTType) -> EntryKind {
            guard let description = type.localizedDescription else {
                // Only the system types `type(_:pathExtension:)` falls back to get here, and
                // each has a description.
                preconditionFailure("\(type.identifier) has no description")
            }
            let text = description.prefix(1).localizedUppercase + description.dropFirst()
            return EntryKind(type: type, text: text)
        }
    }
}
