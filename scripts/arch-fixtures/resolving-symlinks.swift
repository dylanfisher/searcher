// Breaks the resolving-symlinks rule of scripts/arch. Never compiled.
import Foundation

func resolved(_ url: URL) -> URL {
    url.resolvingSymlinksInPath()
}
