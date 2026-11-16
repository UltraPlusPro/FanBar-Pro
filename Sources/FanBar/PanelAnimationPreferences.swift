import Foundation

/// Preference storage for motion inside the menu bar panel: the spinning
/// fan rotors and the control strip's transitions.
enum PanelAnimationPreferences {
    static let preferenceKey = "fanbar.panelAnimationEnabled"

    /// Raw user preference. Enabled by default; only an explicit `false` turns
    /// the panel animation off.
    static var isEnabled: Bool {
        guard UserDefaults.standard.object(forKey: preferenceKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: preferenceKey)
    }

    /// The user's choice AND the non-configurable Low Power Mode constraint:
    /// the system pauses the panel rotors even with the switch on.
    static var isEffectivelyEnabled: Bool {
        isEnabled && !LowPowerMode.isActive
    }
}
