// Breaks the getattrlist rule of scripts/arch. Never compiled.
import Darwin

func read(_ path: String, _ list: inout attrlist, _ buffer: UnsafeMutableRawPointer) -> Int32 {
    getattrlist(path, &list, buffer, 4096, 0)
}
