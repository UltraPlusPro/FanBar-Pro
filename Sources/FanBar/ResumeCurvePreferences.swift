import FanBarShared
import Foundation

/// Remembers the manual fan mode that actually reached the fans, so the opt-in
/// switch in Settings › General can put it back after a login or a restart.
///
/// Everything here is a pure value decision: the controller supplies the live
/// hardware state (helper ready, fans readable, temperature available) and this
/// type answers what may be replayed. Keeping the rules side-effect free lets
/// the decode, the fallback for a deleted custom preset and the "give up"
/// cases be unit-tested without a Mac that has fans.
enum ResumeCurvePreferences {
    /// Settings › General › "Resume the custom fan curve after a restart".
    static let enabledKey = "fanbar.resumeLastCurveOnLaunch"
    /// The mode the last successful manual switch reached, as a `Snapshot` token.
    static let snapshotKey = "fanbar.resumeLastCurveMode"

    /// A manual mode that can be replayed at launch.
    enum Snapshot: Equatable {
        case preset(CoolingPresetID)
        case fixed(Int)
    }

    /// `preset:builtin:3`, `preset:custom:<uuid>` or `fixed:2400`. The preset
    /// half reuses `CoolingPresetID.token`, so custom presets encode exactly
    /// the way the rest of the app persists them.
    static func rawValue(for snapshot: Snapshot) -> String {
        switch snapshot {
        case .preset(let preset): "preset:\(preset.token)"
        case .fixed(let rpm): "fixed:\(rpm)"
        }
    }

    /// Malformed, unknown and half-written values decode to nil rather than to
    /// a partially valid mode.
    static func snapshot(from rawValue: String?) -> Snapshot? {
        guard let rawValue else { return nil }
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "preset":
            guard let preset = CoolingPresetID(token: parts[1]) else { return nil }
            return .preset(preset)
        case "fixed":
            // A zero or negative target is never a mode the user chose.
            guard let rpm = Int(parts[1]), rpm > 0 else { return nil }
            return .fixed(rpm)
        default:
            return nil
        }
    }

    /// A custom preset the user deleted cannot run. The built-in Balanced curve
    /// is the same fallback the app already uses for a missing selection, so a
    /// stale snapshot still produces a real, safe mode instead of failing.
    static func resolvedPreset(
        _ preset: CoolingPresetID,
        available: [CoolingPresetID]
    ) -> CoolingPresetID {
        available.contains(preset) ? preset : .fallback
    }

    /// Fans may report a different range than when the snapshot was written
    /// (a different Mac, or a dock change), so the stored target is clamped
    /// into what the fans can hold right now.
    static func resolvedRPM(_ rpm: Int, in range: ClosedRange<Int>) -> Int {
        min(max(rpm, range.lowerBound), range.upperBound)
    }

    /// 1.1.10: the switch is on for a fresh install, so a curve the user picked
    /// survives a restart without them having to find this row first. An
    /// explicit "off" is stored as `false` and still wins; only a key that was
    /// never written reads as on.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    static func storedSnapshot(defaults: UserDefaults = .standard) -> Snapshot? {
        snapshot(from: defaults.string(forKey: snapshotKey))
    }

    /// Written only after a mode really reached the fans, so a failed switch
    /// never becomes the mode restored at the next launch.
    static func save(_ snapshot: Snapshot, defaults: UserDefaults = .standard) {
        defaults.set(rawValue(for: snapshot), forKey: snapshotKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: snapshotKey)
    }

    /// Turning the switch off forgets the mode, so turning it back on never
    /// restores something the user did not re-arm.
    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
        if !enabled { clear(defaults: defaults) }
    }

    /// The mode a launch may replay, or nil when nothing should happen. The
    /// caller still has to wait for the hardware it needs (fan readings, a
    /// thermal reading), which is why readiness is a separate input.
    static func restoreTarget(
        defaults: UserDefaults = .standard,
        isHelperEnabled: Bool,
        isBusy: Bool,
        isAutomatic: Bool
    ) -> Snapshot? {
        guard isEnabled(defaults: defaults), isHelperEnabled, !isBusy, isAutomatic else {
            return nil
        }
        return storedSnapshot(defaults: defaults)
    }
}
