import Foundation

/// Ajustes de energía de macOS relacionados con la UPS.
public struct SystemPowerSettings: Codable, Sendable, Equatable {
    /// `pmset autorestart`: arrancar automáticamente tras un corte de luz.
    /// `nil` si no se pudo leer.
    public var autoRestart: Bool?
    /// Quien responde puede cambiarlo (el daemon root sí; la app sola no).
    public var canChange: Bool

    public init(autoRestart: Bool?, canChange: Bool) {
        self.autoRestart = autoRestart
        self.canChange = canChange
    }
}

/// Lectura y cambio de `pmset autorestart` ("Arrancar automáticamente tras un corte
/// de luz" en Ajustes del Sistema > Energía). Cambiarlo requiere root.
public enum PowerManagement {
    public static func current() -> SystemPowerSettings {
        SystemPowerSettings(autoRestart: autoRestart(), canChange: geteuid() == 0)
    }

    public static func autoRestart() -> Bool? {
        guard let output = run(["-g"]) else { return nil }
        return parseAutoRestart(output)
    }

    public static func setAutoRestart(_ on: Bool) throws {
        guard geteuid() == 0 else { throw PowerManagementError.notRoot }
        guard run(["-a", "autorestart", on ? "1" : "0"]) != nil else { throw PowerManagementError.failed }
    }

    /// Busca la línea `autorestart N` (sin confundirla con `autorestartatconnect`).
    static func parseAutoRestart(_ output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0] == "autorestart", let v = Int(parts[1]) { return v != 0 }
        }
        return nil
    }

    private static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}

public enum PowerManagementError: Error, CustomStringConvertible {
    case notRoot
    case failed

    public var description: String {
        switch self {
        case .notRoot: "Hace falta el servicio en segundo plano para cambiar este ajuste."
        case .failed: "pmset no pudo cambiar el ajuste."
        }
    }
}
