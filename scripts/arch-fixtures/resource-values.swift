// Breaks the resource-values rule of scripts/arch with setResourceValues, which the rule must
// catch as well as resourceValues. Never compiled.
import Foundation

func hide(_ url: inout URL) throws {
    var values = URLResourceValues()
    values.isHidden = true
    try url.setResourceValues(values)
}
