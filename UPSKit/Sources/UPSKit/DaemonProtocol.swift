import Foundation

/// Interfaz XPC que expone el daemon root a la app. Los datos viajan como JSON
/// (`MonitorSnapshot`, `MonitorSettings`) para no depender de `NSSecureCoding`.
@objc public protocol UPSDaemonProtocol {
    /// Estado actual y eventos posteriores a `eventID` (-1 = sin eventos, solo el último id).
    func snapshot(since eventID: Int, reply: @escaping @Sendable (Data?) -> Void)
    func updateSettings(_ settings: Data, reply: @escaping @Sendable (Bool) -> Void)
    func postpone(minutes: Int, reply: @escaping @Sendable () -> Void)
    func shutdownNow(reply: @escaping @Sendable () -> Void)
    /// Historial de los últimos `days` días (`HistorySnapshot` en JSON).
    func history(days: Int, reply: @escaping @Sendable (Data?) -> Void)
    /// Borra el historial y, si `includeLogs`, el registro del daemon.
    func clearHistory(includeLogs: Bool, reply: @escaping @Sendable () -> Void)
    /// Fusiona un historial JSONL (el de la app en modo local). Responde cuántas líneas tenía.
    func mergeHistory(_ jsonl: Data, reply: @escaping @Sendable (Int) -> Void)
    /// Test rápido de batería (`BatteryTestResponse` en JSON). Tarda ~10 s.
    func runBatteryTest(reply: @escaping @Sendable (Data?) -> Void)
    /// Inicia una prueba de descarga para calibrar (`CalibrationResponse` en JSON).
    func startCalibration(maxMinutes: Int, reply: @escaping @Sendable (Data?) -> Void)
    func cancelCalibration(reply: @escaping @Sendable () -> Void)
    /// Serie temporal del panel (`[SeriesPoint]` en JSON) para `minutes` (60, 360 o 1440).
    func series(minutes: Int, reply: @escaping @Sendable (Data?) -> Void)
    /// Ajustes de energía de macOS (`SystemPowerSettings` en JSON).
    func powerSettings(reply: @escaping @Sendable (Data?) -> Void)
    /// Cambia `pmset autorestart`. Responde el error, o `nil` si salió bien.
    func setAutoRestart(_ on: Bool, reply: @escaping @Sendable (String?) -> Void)
}

/// Identidades y requisitos de firma compartidos por la app y el daemon.
public enum DaemonIdentity {
    public static let teamID = "L77R5X2WV6"
    /// Identificador de firma del ejecutable del daemon.
    public static let daemonCodeIdentifier = "com.xreq403.UPSForza.daemon"
    public static let appIdentifiers = ["com.xreq403.UPSForza", "com.xreq403.UPSForza.debug"]

    /// Label de launchd y nombre del servicio Mach, por build de la app:
    /// `com.xreq403.UPSForza.daemon` (Release) o `com.xreq403.UPSForza.debug.daemon` (Debug).
    public static func label(forAppBundleID id: String) -> String { id + ".daemon" }

    /// Labels de todos los daemons posibles (Release y Debug).
    public static var allLabels: [String] { appIdentifiers.map(label(forAppBundleID:)) }

    /// El daemon solo acepta conexiones de la app firmada por el equipo.
    public static var clientRequirement: String {
        let ids = appIdentifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and (\(ids))"
    }

    /// La app solo habla con el daemon firmado por el equipo.
    public static var daemonRequirement: String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(daemonCodeIdentifier)\""
    }

    public static let jsonEncoder = JSONEncoder()
    public static let jsonDecoder = JSONDecoder()
}
