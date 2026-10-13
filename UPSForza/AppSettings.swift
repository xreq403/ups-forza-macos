import Foundation
import UPSKit

/// Claves de `UserDefaults`. Las vistas usan `@AppStorage` con estas mismas claves.
enum SettingsKey {
    static let pollInterval = "pollInterval"
    static let shutdownOnUPSLowBattery = "shutdownOnUPSLowBattery"
    static let minBatteryPercent = "minBatteryPercent"
    static let maxMinutesOnBattery = "maxMinutesOnBattery"
    static let warningSeconds = "warningSeconds"
    static let beeperEnabled = "beeperEnabled"
}

enum AppSettings {
    static func registerDefaults() {
        let policy = ShutdownPolicy()
        UserDefaults.standard.register(defaults: [
            SettingsKey.pollInterval: 5,
            SettingsKey.shutdownOnUPSLowBattery: policy.onUPSLowBattery,
            SettingsKey.minBatteryPercent: policy.minBatteryPercent,
            SettingsKey.maxMinutesOnBattery: policy.maxMinutesOnBattery,
            SettingsKey.warningSeconds: policy.warningSeconds,
            SettingsKey.beeperEnabled: true,
        ])
    }

    static var pollInterval: Int { max(UserDefaults.standard.integer(forKey: SettingsKey.pollInterval), 1) }
    static var beeperEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.beeperEnabled) }

    static var policy: ShutdownPolicy {
        let d = UserDefaults.standard
        var p = ShutdownPolicy()
        p.onUPSLowBattery = d.bool(forKey: SettingsKey.shutdownOnUPSLowBattery)
        p.minBatteryPercent = d.integer(forKey: SettingsKey.minBatteryPercent)
        p.maxMinutesOnBattery = d.integer(forKey: SettingsKey.maxMinutesOnBattery)
        p.warningSeconds = d.integer(forKey: SettingsKey.warningSeconds)
        return p
    }
}

extension TimeInterval {
    /// "1 h 05 min", "4 min 12 s", "35 s".
    var durationText: String {
        let s = Int(self.rounded())
        if s >= 3600 { return "\(s / 3600) h \(String(format: "%02d", s % 3600 / 60)) min" }
        if s >= 60 { return "\(s / 60) min \(s % 60) s" }
        return "\(s) s"
    }
}
