// Breaks the bundle-at-path rule of scripts/arch. Never compiled.
import Foundation

func bundleID(at url: URL) -> String? {
    Bundle(url: url)?.bundleIdentifier
}
