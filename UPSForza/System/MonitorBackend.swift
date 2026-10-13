import Foundation
import UPSKit

/// De dónde obtiene la app el estado de la UPS.
protocol MonitorBackend: AnyObject, Sendable {
    func start() async
    /// Libera los recursos (el USB en el modo local, la conexión XPC con el daemon).
    func stop() async
    func snapshot(since eventID: Int) async throws -> MonitorSnapshot
    func update(settings: MonitorSettings) async throws
    func postpone(minutes: Int) async throws
    func shutdownNow() async throws
    func history(days: Int) async throws -> HistorySnapshot
    func clearHistory(includeLogs: Bool) async throws
    func powerSettings() async throws -> SystemPowerSettings
    func setAutoRestart(_ on: Bool) async throws
    func runBatteryTest() async throws -> BatteryTestResponse
}

/// Historial de la app en modo local (sin daemon).
enum LocalHistory {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/UPSForza/history.jsonl")
    }
    /// Copia ya enviada al daemon: no se vuelve a enviar.
    static var mergedURL: URL { url.deletingPathExtension().appendingPathExtension("merged.jsonl") }

    /// Historial del daemon de esta build (legible por los usuarios).
    static var daemonURL: URL {
        let debug = Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true
        return URL(fileURLWithPath: "/Library/Application Support/UPSForza/history\(debug ? "-debug" : "").jsonl")
    }

    /// Prepara el historial local antes de arrancar el monitor local:
    /// - si no hay historial local, parte de una copia del daemon (para ver lo mismo
    ///   en los dos modos, aunque el servicio se haya desactivado desde Ajustes del Sistema);
    /// - solo si no existe ningún historial se importan los registros de texto.
    /// Devuelve los registros a importar (vacío si no corresponde).
    static func prepare() -> [URL] {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return [] }
        if let data = try? Data(contentsOf: daemonURL), !data.isEmpty {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            return []
        }
        if fm.fileExists(atPath: mergedURL.path) || fm.fileExists(atPath: daemonURL.path) { return [] }
        return [
            EventLog.userLogURL.deletingPathExtension().appendingPathExtension("1.log"),
            EventLog.userLogURL,
        ]
    }
}

// MARK: - Local (sin daemon)

/// La app consulta la UPS por su cuenta. Sin privilegios: si una app bloquea el
/// apagado ordenado, solo se puede volver a avisar.
final class LocalBackend: MonitorBackend {
    private let core: MonitorCore

    init(settings: MonitorSettings) {
        core = MonitorCore(
            device: ForzaUPS(),
            settings: settings,
            log: EventLog(url: EventLog.userLogURL),
            forced: .unavailable(retryAfter: 120),
            historyURL: LocalHistory.url,
            importLogs: LocalHistory.prepare()
        )
    }

    func start() async { await core.start() }
    func stop() async { await core.stop() }
    func snapshot(since eventID: Int) async throws -> MonitorSnapshot { await core.snapshot(since: eventID) }
    func update(settings: MonitorSettings) async throws { await core.update(settings: settings) }
    func postpone(minutes: Int) async throws { await core.postpone(minutes: minutes) }
    func shutdownNow() async throws { await core.shutdownNow() }
    func history(days: Int) async throws -> HistorySnapshot { await core.history(days: days) }
    func clearHistory(includeLogs: Bool) async throws { await core.clearHistory(includeLogs: includeLogs) }
    func powerSettings() async throws -> SystemPowerSettings { PowerManagement.current() }
    func runBatteryTest() async throws -> BatteryTestResponse { await core.runBatteryTest(trigger: .manual) }
    func setAutoRestart(_ on: Bool) async throws { throw PowerManagementError.notRoot }
}

// MARK: - Daemon root por XPC

struct DaemonCommandError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum DaemonBackendError: Error, CustomStringConvertible {
    case noProxy
    case badReply
    case timeout

    var description: String {
        switch self {
        case .noProxy: "No se pudo conectar con el servicio"
        case .badReply: "Respuesta inválida del servicio"
        case .timeout: "El servicio no responde"
        }
    }
}

final class DaemonBackend: MonitorBackend, @unchecked Sendable {
    private let connection: NSXPCConnection

    init(label: String) {
        connection = NSXPCConnection(machServiceName: label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: UPSDaemonProtocol.self)
        // Solo hablar con el daemon firmado por el equipo.
        connection.setCodeSigningRequirement(DaemonIdentity.daemonRequirement)
        connection.resume()
    }

    func start() async {}

    func stop() async {
        connection.invalidate()
    }

    /// ¿Hay un daemon con este label corriendo y aceptando a esta app?
    static func isReachable(label: String) async -> Bool {
        let probe = DaemonBackend(label: label)
        defer { probe.connection.invalidate() }
        return (try? await probe.snapshot(since: -1)) != nil
    }

    func snapshot(since eventID: Int) async throws -> MonitorSnapshot {
        let data: Data = try await call { proxy, done in
            proxy.snapshot(since: eventID) { data in
                done(data.map { .success($0) } ?? .failure(DaemonBackendError.badReply))
            }
        }
        return try DaemonIdentity.jsonDecoder.decode(MonitorSnapshot.self, from: data)
    }

    func update(settings: MonitorSettings) async throws {
        let data = try DaemonIdentity.jsonEncoder.encode(settings)
        let ok: Bool = try await call { proxy, done in
            proxy.updateSettings(data) { done(.success($0)) }
        }
        if !ok { throw DaemonBackendError.badReply }
    }

    func postpone(minutes: Int) async throws {
        try await call { proxy, done in proxy.postpone(minutes: minutes) { done(.success(())) } }
    }

    func shutdownNow() async throws {
        try await call { proxy, done in proxy.shutdownNow { done(.success(())) } }
    }

    func clearHistory(includeLogs: Bool) async throws {
        try await call { proxy, done in proxy.clearHistory(includeLogs: includeLogs) { done(.success(())) } }
    }

    func mergeHistory(_ jsonl: Data) async throws -> Int {
        try await call(timeout: 15) { proxy, done in proxy.mergeHistory(jsonl) { done(.success($0)) } }
    }

    func runBatteryTest() async throws -> BatteryTestResponse {
        let data: Data = try await call(timeout: 45) { proxy, done in
            proxy.runBatteryTest { data in
                done(data.map { .success($0) } ?? .failure(DaemonBackendError.badReply))
            }
        }
        return try DaemonIdentity.jsonDecoder.decode(BatteryTestResponse.self, from: data)
    }

    func powerSettings() async throws -> SystemPowerSettings {
        let data: Data = try await call { proxy, done in
            proxy.powerSettings { data in
                done(data.map { .success($0) } ?? .failure(DaemonBackendError.badReply))
            }
        }
        return try DaemonIdentity.jsonDecoder.decode(SystemPowerSettings.self, from: data)
    }

    func setAutoRestart(_ on: Bool) async throws {
        let error: String? = try await call { proxy, done in proxy.setAutoRestart(on) { done(.success($0)) } }
        if let error { throw DaemonCommandError(message: error) }
    }

    func history(days: Int) async throws -> HistorySnapshot {
        let data: Data = try await call { proxy, done in
            proxy.history(days: days) { data in
                done(data.map { .success($0) } ?? .failure(DaemonBackendError.badReply))
            }
        }
        return try DaemonIdentity.jsonDecoder.decode(HistorySnapshot.self, from: data)
    }

    /// Llama al daemon y espera la respuesta, con un límite (`timeout`) por si no responde.
    private func call<T: Sendable>(
        timeout: TimeInterval = 5,
        _ body: @escaping (UPSDaemonProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let once = ResumeOnce<T>()
        return try await withCheckedThrowingContinuation { cont in
            once.set(cont)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(error))
            }
            guard let proxy = proxy as? UPSDaemonProtocol else {
                once.resume(.failure(DaemonBackendError.noProxy))
                return
            }
            body(proxy) { once.resume($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(.failure(DaemonBackendError.timeout))
            }
        }
    }
}

/// Reanuda una continuación una sola vez (respuesta, error de XPC o timeout).
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?

    func set(_ c: CheckedContinuation<T, Error>) { lock.withLock { cont = c } }

    func resume(_ result: Result<T, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { cont = nil }
            return cont
        }
        c?.resume(with: result)
    }
}
