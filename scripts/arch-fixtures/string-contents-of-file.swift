// Breaks the string-contents-of-file rule of scripts/arch. Never compiled.
import Foundation

func text(at path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}
