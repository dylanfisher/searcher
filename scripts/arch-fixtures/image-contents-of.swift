// Breaks the image-contents-of rule of scripts/arch. Never compiled.
import AppKit

func image(at url: URL) -> NSImage? {
    NSImage(contentsOf: url)
}
