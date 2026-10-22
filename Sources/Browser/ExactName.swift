/// A file name hashed and compared by its UTF-8 bytes. `String`'s own `==` treats canonically
/// equivalent names as equal, and a case-sensitive or SMB volume can hold both as separate files.
public struct ExactName: Hashable, Sendable {
    public let name: String

    public init(_ name: String) { self.name = name }

    public static func == (a: ExactName, b: ExactName) -> Bool {
        a.name.utf8.elementsEqual(b.name.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        var name = name
        name.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
}
