// Breaks the lstat-family rule of scripts/arch. Never compiled.
import Darwin

func isLink(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}
