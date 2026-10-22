// Breaks the data-contents-of rule of scripts/arch. Never compiled.
import Foundation

func bytes(at url: URL) throws -> Data {
    try Data(contentsOf: url)
}
