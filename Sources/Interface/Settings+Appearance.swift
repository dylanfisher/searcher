import AppKit
import Browser

extension Settings.Appearance {
    /// The AppKit appearance it names; nil for Auto, which leaves the choice to the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension Settings {
    /// Gives `target` the `appearance` setting, now and after each change, for as long as
    /// `target` exists. The app passes `NSApp`, so every window and view takes it; views that
    /// draw resolve their colors against their own `effectiveAppearance`. Tests pass a view.
    public func applyAppearance(to target: NSObject & NSAppearanceCustomization) {
        target.appearance = appearance.nsAppearance
        observe(for: target) { [weak self, weak target] in
            guard let self, let target else { return }
            let wanted = appearance.nsAppearance
            guard target.appearance?.name != wanted?.name else { return }
            target.appearance = wanted
        }
    }
}
