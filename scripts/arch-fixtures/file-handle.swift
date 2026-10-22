// Breaks the file-handle rule of scripts/arch. Never compiled.
import Foundation

func open(_ path: String) -> FileHandle? {
    FileHandle(forReadingAtPath: path)
}
