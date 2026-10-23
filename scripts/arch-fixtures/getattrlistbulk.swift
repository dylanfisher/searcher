// Breaks the getattrlistbulk rule of scripts/arch. Never compiled.
import Darwin

func readSome(_ fd: Int32, _ list: inout attrlist, _ buffer: UnsafeMutableRawPointer) -> Int32 {
    getattrlistbulk(fd, &list, buffer, 4096, 0)
}
