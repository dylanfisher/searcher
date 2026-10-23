// Breaks the statfs rule of scripts/arch. Never compiled.
import Darwin

func isMounted(_ path: String) -> Bool {
    var info = statfs()
    return statfs(path, &info) == 0
}
