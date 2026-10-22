// Breaks the string-contents-of rule of scripts/arch. Never compiled.
import Foundation

func text(at url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}
