// Breaks the url-without-directory rule of scripts/arch. Never compiled.
import Foundation

func urls(for folder: Location, name: String) -> [URL] {
    // The first says whether it is a folder, so building it reads nothing; the second doesn't,
    // so the URL initializer stats the path.
    [
        URL(fileURLWithPath: folder.child(named: name).path, isDirectory: true),
        URL(fileURLWithPath: folder.child(named: name).path),
    ]
}
