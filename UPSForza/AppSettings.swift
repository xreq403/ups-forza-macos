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

    /// Ajustes que se envían al monitor (daemon o local).
    static var monitorSettings: MonitorSettings {
        var s = MonitorSettings()
        s.pollInterval = pollInterval
        s.policy = policy
        s.beeperEnabled = beeperEnabled
        return s
    }

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
