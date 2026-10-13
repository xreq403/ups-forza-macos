// UPSForzaDaemon — daemon root de UPS Forza.
//
// Lo instala la app con SMAppService (plist en Contents/Library/LaunchDaemons) y
// launchd lo mantiene vivo. Es el dueño del monitoreo: lee la UPS, aplica la
// política de apagado y, si hace falta, fuerza el apagado con `shutdown -h now`,
// aunque no haya ninguna sesión abierta. La app se conecta por XPC para mostrar
// el estado, cambiar ajustes y pedir el apagado ordenado en la sesión del usuario.
//
// Argumentos (desde el plist): UPSForzaDaemon <label>

import Foundation
import UPSKit

let label = CommandLine.arguments.dropFirst().first ?? DaemonIdentity.label(forAppBundleID: "com.xreq403.UPSForza")
let isDebug = label.contains(".debug.")
let suffix = isDebug ? "-debug" : ""

let supportDir = URL(fileURLWithPath: "/Library/Application Support/UPSForza")
let settingsURL = supportDir.appending(path: "settings\(suffix).json")
let logURL = URL(fileURLWithPath: "/Library/Logs/UPSForza/ups-forza\(suffix).log")
let log = EventLog(url: logURL)
let historyURL = supportDir.appending(path: "history\(suffix).jsonl")
let seriesURL = supportDir.appending(path: "series\(suffix).json")

/// Registros de texto para reconstruir el historial la primera vez: el del daemon
/// y los de la app en modo local de cada usuario (`~/Library/Logs/ups-forza.log`).
nonisolated func logsToImport() -> [URL] {
    var urls = [logURL.deletingPathExtension().appendingPathExtension("1.log"), logURL]
    let users = (try? FileManager.default.contentsOfDirectory(atPath: "/Users")) ?? []
    for user in users where !user.hasPrefix(".") && user != "Shared" {
        let base = URL(fileURLWithPath: "/Users/\(user)/Library/Logs")
        urls += [base.appending(path: "ups-forza.1.log"), base.appending(path: "ups-forza.log")]
    }
    return urls
}

// MARK: - Ajustes persistidos (para funcionar sin sesión abierta)

nonisolated func loadSettings() -> MonitorSettings {
    guard let data = try? Data(contentsOf: settingsURL),
          let s = try? DaemonIdentity.jsonDecoder.decode(MonitorSettings.self, from: data)
    else { return MonitorSettings() }
    return s
}

nonisolated func saveSettings(_ s: MonitorSettings) {
    do {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try DaemonIdentity.jsonEncoder.encode(s).write(to: settingsURL, options: .atomic)
    } catch {
        log.write("ERROR guardando ajustes: \(error)")
    }
}

// MARK: - Clientes conectados

/// Recuerda cuándo consultó la app por última vez. Si consultó hace poco, hay
/// una sesión con la app abierta que puede hacer el apagado ordenado.
final class ClientTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastContact = Date.distantPast

    func touch() { lock.withLock { lastContact = .now } }
    var isActive: Bool { lock.withLock { Date.now.timeIntervalSince(lastContact) < 10 } }
}

let clients = ClientTracker()

// MARK: - Apagado forzado

/// La llama `MonitorCore` desde su actor: no debe depender del MainActor.
nonisolated func forceShutdown(_ reason: ShutdownReason) {
    log.write("shutdown -h now (\(reason))")
    log.flush()   // el apagado mata el proceso: que el registro llegue al disco antes
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/sbin/shutdown")
    p.arguments = ["-h", "now", "UPS Forza: \(reason)"]
    do {
        try p.run()
    } catch {
        log.write("ERROR ejecutando shutdown: \(error)")
    }
}

// Sin ajustes guardados (primer arranque) no se toca la alarma hasta que la app envíe los del usuario.
let savedSettings = FileManager.default.fileExists(atPath: settingsURL.path)
let core = MonitorCore(
    device: ForzaUPS(),
    settings: loadSettings(),
    log: log,
    forced: .available(grace: 90, hasActiveClient: { clients.isActive }, execute: forceShutdown),
    enforceBeeper: savedSettings,
    historyURL: historyURL,
    importLogs: logsToImport(),
    seriesURL: seriesURL
)

// MARK: - XPC

final class DaemonService: NSObject, UPSDaemonProtocol {
    func snapshot(since eventID: Int, reply: @escaping @Sendable (Data?) -> Void) {
        clients.touch()
        Task {
            let snap = await core.snapshot(since: eventID)
            reply(try? DaemonIdentity.jsonEncoder.encode(snap))
        }
    }

    func updateSettings(_ data: Data, reply: @escaping @Sendable (Bool) -> Void) {
        clients.touch()
        guard let s = try? DaemonIdentity.jsonDecoder.decode(MonitorSettings.self, from: data) else {
            reply(false)
            return
        }
        Task {
            await core.update(settings: s)
            saveSettings(s)
            reply(true)
        }
    }

    func postpone(minutes: Int, reply: @escaping @Sendable () -> Void) {
        clients.touch()
        Task {
            await core.postpone(minutes: minutes)
            reply()
        }
    }

    func shutdownNow(reply: @escaping @Sendable () -> Void) {
        clients.touch()
        Task {
            await core.shutdownNow()
            reply()
        }
    }

    func mergeHistory(_ jsonl: Data, reply: @escaping @Sendable (Int) -> Void) {
        clients.touch()
        Task { reply(await core.mergeHistory(jsonl)) }
    }

    func clearHistory(includeLogs: Bool, reply: @escaping @Sendable () -> Void) {
        clients.touch()
        Task {
            await core.clearHistory(includeLogs: includeLogs)
            reply()
        }
    }

    func runBatteryTest(reply: @escaping @Sendable (Data?) -> Void) {
        clients.touch()
        Task {
            let response = await core.runBatteryTest(trigger: .manual)
            reply(try? DaemonIdentity.jsonEncoder.encode(response))
        }
    }

    func series(minutes: Int, reply: @escaping @Sendable (Data?) -> Void) {
        clients.touch()
        Task {
            let range = SeriesRange(rawValue: minutes) ?? .hour1
            reply(try? DaemonIdentity.jsonEncoder.encode(await core.series(range)))
        }
    }

    func powerSettings(reply: @escaping @Sendable (Data?) -> Void) {
        reply(try? DaemonIdentity.jsonEncoder.encode(PowerManagement.current()))
    }

    func setAutoRestart(_ on: Bool, reply: @escaping @Sendable (String?) -> Void) {
        clients.touch()
        do {
            try PowerManagement.setAutoRestart(on)
            log.write("pmset autorestart \(on ? 1 : 0) (encender la Mac al volver la luz: \(on ? "sí" : "no"))")
            reply(nil)
        } catch {
            log.write("ERROR cambiando pmset autorestart: \(error)")
            reply(String(describing: error))
        }
    }

    func history(days: Int, reply: @escaping @Sendable (Data?) -> Void) {
        Task {
            let snap = await core.history(days: days)
            reply(try? DaemonIdentity.jsonEncoder.encode(snap))
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = DaemonService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Solo la app firmada por el equipo; cualquier otro cliente queda invalidado.
        connection.setCodeSigningRequirement(DaemonIdentity.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: UPSDaemonProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: label)
listener.delegate = delegate
listener.resume()

// MARK: - Actualización

/// Si se reinstala la app, el ejecutable se reemplaza en disco: salir para que
/// launchd (KeepAlive) levante la versión nueva, sin tener que reiniciar la Mac.
/// Se compara el inodo y la fecha del archivo real del proceso (`proc_pidpath`);
/// si no se pueden leer, no se reinicia nunca.
struct ExecutableStamp: Equatable {
    let inode: UInt64
    let mtime: Int
}

let executablePath: String? = {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(getpid(), &buf, UInt32(buf.count)) > 0 else { return nil }
    return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}()

nonisolated func executableStamp() -> ExecutableStamp? {
    guard let executablePath else { return nil }
    var st = stat()
    guard stat(executablePath, &st) == 0 else { return nil }
    return ExecutableStamp(inode: UInt64(st.st_ino), mtime: st.st_mtimespec.tv_sec)
}

let launchStamp = executableStamp()
// En la cola principal: el código de nivel superior de main.swift está aislado al
// MainActor y un closure ejecutado en otra cola hace abortar el proceso.
let updateTimer = DispatchSource.makeTimerSource(queue: .main)
if let launchStamp {
    updateTimer.schedule(deadline: .now() + 60, repeating: 60)
    updateTimer.setEventHandler {
        // Durante la instalación el archivo puede faltar un instante: solo actuar si hay uno distinto.
        guard let current = executableStamp(), current != launchStamp else { return }
        log.write("El daemon se actualizó en disco (\(executablePath ?? "?")); reiniciando")
        Task {
            await core.stop()
            log.flush()
            exit(0)
        }
    }
    updateTimer.resume()
} else {
    log.write("No se pudo leer el ejecutable del daemon; sin detección de actualizaciones")
}

log.write("Inicio del daemon \(label) (pid \(ProcessInfo.processInfo.processIdentifier))")
Task { await core.start() }
dispatchMain()
