// Breaks the get-resource-value rule of scripts/arch. Never compiled.
import Foundation

func isFolder(_ url: NSURL) throws -> Bool {
    var value: AnyObject?
    try url.getResourceValue(&value, forKey: .isDirectoryKey)
    return (value as? Bool) ?? false
}
