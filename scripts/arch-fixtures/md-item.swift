// Breaks the md-item rule of scripts/arch. Never compiled.
import CoreServices
import Foundation

func lastOpened(_ path: String) -> Date? {
    MDItemCreate(nil, path as CFString).flatMap {
        MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date
    }
}
