// Breaks the nsdata-contents-of rule of scripts/arch, by path and by URL. Never compiled.
import Foundation

func bytes(atPath path: String) -> NSData? {
    NSData(contentsOfFile: path)
}

func bytes(at url: URL) -> NSData? {
    NSData(contentsOf: url)
}
