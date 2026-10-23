// Breaks the image-contents-of-file rule of scripts/arch. Never compiled.
import AppKit

func image(at path: String) -> NSImage? {
    NSImage(contentsOfFile: path)
}
