// Breaks the fstatfs rule of scripts/arch. Never compiled.
import Darwin

func isMounted(_ descriptor: Int32) -> Bool {
    var info = Darwin.statfs()
    return fstatfs(descriptor, &info) == 0
}
