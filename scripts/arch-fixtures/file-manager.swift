// Breaks the file-manager rule of scripts/arch. Never compiled.
import Foundation

func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}
