// Breaks the icon-for-file rule of scripts/arch, with the call split across lines and the
// forFiles: variant. Never compiled.
import AppKit

func icon(at path: String) -> NSImage {
    NSWorkspace.shared.icon(
        forFile: path)
}

func icon(for paths: [String]) -> NSImage? {
    NSWorkspace.shared.icon(forFiles: paths)
}
