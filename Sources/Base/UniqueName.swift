import Darwin
import Foundation
import UniformTypeIdentifiers

/// The names Finder gives a duplicate, a copy kept beside an item of the same name, and a new
/// folder. `isTaken` says whether the folder already has a name; on a case-insensitive volume it
/// has to answer without case, as `isTaken(_:in:)` does. `UniqueNameTests` lists Finder's names
/// these follow.
///
/// A name splits into base and extension only where a declared type has that extension, as
/// Finder splits it: "archive.tar.gz" is "archive.tar" and "gz", "App.app" is "App" and "app",
/// and ".zshrc", "Photos.2024" and "x.qqq" have no extension. That holds for folders too:
/// a folder named "Stuff.txt" duplicates as "Stuff copy.txt". A name too long for the suffix is
/// shortened by whole characters before it; Finder refuses to duplicate it instead. See
/// docs/decisions/0063-move-and-names.md.
public enum UniqueName {
    /// Finder's Duplicate: "name copy.ext", then "name copy 2.ext" and on. A name that already
    /// ends in " copy" or " copy N" continues from it: "name copy.ext" duplicates as
    /// "name copy 2.ext".
    public static func duplicate<Failure: Error>(
        of name: String, isTaken: (String) throws(Failure) -> Bool
    ) throws(Failure) -> String {
        let (base, pathExtension) = split(name)
        let marker = " copy"
        if let (prefix, number) = trailingNumber(base), prefix.hasSuffix(marker) {
            return try firstFree(
                String(prefix.dropLast(marker.count)), marker, pathExtension, from: number + 1,
                isTaken: isTaken)
        }
        if base.hasSuffix(marker) {
            return try firstFree(
                String(base.dropLast(marker.count)), marker, pathExtension, from: 2,
                isTaken: isTaken)
        }
        return try firstFree(base, marker, pathExtension, unnumberedFirst: true, isTaken: isTaken)
    }

    /// Finder's Keep Both: "name 2.ext", then "name 3.ext" and on. Unlike Duplicate, a name that
    /// already ends in a number keeps it: "name 2.ext" becomes "name 2 2.ext".
    public static func keepingBoth<Failure: Error>(
        _ name: String, isTaken: (String) throws(Failure) -> Bool
    ) throws(Failure) -> String {
        let (base, pathExtension) = split(name)
        return try firstFree(base, "", pathExtension, from: 2, isTaken: isTaken)
    }

    /// Finder's New Folder: "untitled folder", then "untitled folder 2" and on.
    public static func newFolder<Failure: Error>(
        isTaken: (String) throws(Failure) -> Bool
    ) throws(Failure) -> String {
        try firstFree("untitled folder", "", nil, unnumberedFirst: true, isTaken: isTaken)
    }

    /// Whether `folder` has an item named `name`, asked of the file system so it answers as the
    /// volume compares names. Blocks the calling thread; call it off the main thread.
    public static func isTaken(_ name: String, in folder: String) throws(FileOperationError)
        -> Bool
    {
        preconditionOffMain("UniqueName")
        let path = join(folder, name)
        var info = stat()
        if lstat(path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw FileOperationError(errno: errno, path: path)
    }

    /// The name's base and its extension, if a declared type has that extension.
    public static func split(_ name: String) -> (base: String, pathExtension: String?) {
        let pathExtension = (name as NSString).pathExtension
        guard !pathExtension.isEmpty,
            UTType(filenameExtension: pathExtension, conformingTo: .item)?.isDeclared == true
        else { return (name, nil) }
        return ((name as NSString).deletingPathExtension, pathExtension)
    }

    /// The text before a trailing " N", and N, if `base` ends in a space and ASCII digits.
    private static func trailingNumber(_ base: String) -> (Substring, Int)? {
        let digits = base.utf8.reversed().prefix { (0x30...0x39).contains($0) }.count
        guard digits > 0 else { return nil }
        let numberStart = base.utf8.index(base.utf8.endIndex, offsetBy: -digits)
        guard numberStart > base.utf8.startIndex else { return nil }
        let space = base.utf8.index(before: numberStart)
        // A number too large for Int has no next number, so it is part of the name.
        guard base.utf8[space] == UInt8(ascii: " "),
            let number = Int(base[numberStart...]), number < Int.max
        else { return nil }
        return (base[..<space], number)
    }

    /// The first name `isTaken` refuses of `core` + `marker` + " N" + extension, for N counting
    /// up from `from`, after the name without a number if `unnumberedFirst`.
    private static func firstFree<Failure: Error>(
        _ core: String, _ marker: String, _ pathExtension: String?, unnumberedFirst: Bool = false,
        from first: Int = 2, isTaken: (String) throws(Failure) -> Bool
    ) throws(Failure) -> String {
        if unnumberedFirst {
            let name = fitted(core, marker + (pathExtension.map { "." + $0 } ?? ""))
            if try !isTaken(name) { return name }
        }
        var number = first
        while true {
            let name = fitted(
                core, marker + " \(number)" + (pathExtension.map { "." + $0 } ?? ""))
            if try !isTaken(name) { return name }
            number += 1
        }
    }

    /// `core` + `suffix`, with `core` shortened by whole characters until it fits
    /// `FileNameRule.maxBytes`.
    private static func fitted(_ core: String, _ suffix: String) -> String {
        let room = FileNameRule.maxBytes - suffix.utf8.count
        precondition(room >= 0, "the suffix \(suffix) alone is longer than a file name")
        var bytes = 0
        let kept = core.prefix { character in
            bytes += character.utf8.count
            return bytes <= room
        }
        return kept + suffix
    }
}
