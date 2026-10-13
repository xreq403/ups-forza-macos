import Foundation

// MARK: - Dispositivo

/// Lo que `MonitorCore` necesita de la UPS. `ForzaUPS` lo implementa; los tests usan uno simulado.
public protocol UPSDevice: Sendable {
    func start(onConnectionChange: @escaping @Sendable (Bool) -> Void)
    func stop()
    func status() async throws -> UPSStatus
    func protocolVariant() async throws -> String
    func setBeeper(enabled: Bool) async throws -> Bool
}

extension ForzaUPS: UPSDevice {
    public func start(onConnectionChange: @escaping @Sendable (Bool) -> Void) {
        transport.onConnectionChange = onConnectionChange
        start()
    }

    public func stop() {
        transport.stop()
    }
}

// MARK: - Modelo compartido con la app (también viaja por XPC como JSON)

public struct MonitorSettings: Codable, Sendable, Equatable {
    public var pollInterval = 5
    public var policy = ShutdownPolicy()
    public var beeperEnabled = true

    public init() {}
}

public enum LinkState: String, Codable, Sendable {
    /// Nunca se conectó desde que arrancó el monitor.
    case searching
    case connected
    case lost
}

public enum CoreEvent: Codable, Sendable, Equatable {
    case monitor(MonitorEvent)
    /// Sin privilegios: el apagado ordenado no se completó y se volverá a avisar.
    case shutdownIncomplete
    /// El daemon forzó el apagado (`shutdown -h now`).
    case shutdownForced(reason: ShutdownReason)
}

public struct RecordedEvent: Codable, Sendable, Equatable {
    public let id: Int
    public let date: Date
    public let event: CoreEvent
}

public struct MonitorSnapshot: Codable, Sendable {
    public var status: UPSStatus?
    public var link: LinkState
    public var phase: PowerPhase
    public var lastUpdate: Date?
    public var protocolVariant: String?
    public var lastError: String?
    public var beeperSyncing: Bool
    public var beeperSyncError: String?
    public var settings: MonitorSettings
    /// Eventos posteriores al id pedido.
    public var events: [RecordedEvent]
    /// Id del último evento registrado; pedir el próximo snapshot desde aquí.
    public var lastEventID: Int
    public var logPath: String
}

/// Qué hacer si, tras ordenar el apagado, la Mac sigue encendida.
public enum ForcedShutdown: Sendable {
    /// Sin privilegios (la app sola): si el apagado ordenado no se completa en
    /// `retryAfter` segundos, se vuelve a avisar.
    case unavailable(retryAfter: TimeInterval)
    /// Daemon root. Si hay una app conectada, ella intenta el apagado ordenado y,
    /// si en `grace` segundos la Mac sigue encendida, se ejecuta `execute`.
    /// Sin app conectada (p. ej. sin sesión abierta), `execute` se llama de inmediato.
    case available(
        grace: TimeInterval,
        hasActiveClient: @Sendable () -> Bool,
        execute: @Sendable (ShutdownReason) -> Void
    )
}

// MARK: - Núcleo

/// Consulta la UPS periódicamente, aplica la política de apagado, mantiene la
/// alarma sonora según los ajustes y registra eventos. No tiene UI: lo usan el
/// daemon root y, si el daemon no está activo, la app.
public actor MonitorCore {
    private let device: UPSDevice
    private let log: EventLog
    private let forced: ForcedShutdown

    private(set) var settings: MonitorSettings
    private var engine: ShutdownEngine
    private var status: UPSStatus?
    private var link: LinkState = .searching
    private var lastUpdate: Date?
    private var protocolVariant: String?
    private var lastError: String?
    private var beeperSyncing = false
    private var beeperSyncError: String?
    private var beeperTarget: Bool?
    private var beeperAttempts = 0
    /// `false` hasta tener ajustes confiables (p. ej. el daemon en su primer arranque,
    /// antes de que la app le envíe los del usuario): no se toca la alarma.
    private var beeperEnforced: Bool
    private static let maxBeeperAttempts = 3

    private var events: [RecordedEvent] = []
    private var nextEventID = 1
    private static let maxEvents = 200

    private let history: HistoryStore?
    private let importLogs: [URL]
    private var loopTask: Task<Void, Never>?
    private var polling = false
    private var lastReadingLogged = Date.distantPast

    public init(
        device: UPSDevice,
        settings: MonitorSettings,
        log: EventLog,
        forced: ForcedShutdown,
        enforceBeeper: Bool = true,
        historyURL: URL? = nil,
        importLogs: [URL] = []
    ) {
        self.history = historyURL.map(HistoryStore.init)
        self.importLogs = importLogs
        self.device = device
        self.settings = settings
        self.beeperEnforced = enforceBeeper
        self.log = log
        self.forced = forced
        self.engine = ShutdownEngine(policy: settings.policy)
    }

    // MARK: Ciclo de vida

    public func start() {
        guard loopTask == nil else { return }
        log.write("Inicio del monitor")
        importHistoryIfNeeded()
        device.start { [weak self] connected in
            Task { await self?.connectionChanged(connected) }
        }
        loopTask = Task {
            while !Task.isCancelled {
                await pollOnce()
                // Espera el intervalo en pasos de 1 s para que la cuenta regresiva avance a tiempo.
                for _ in 0..<max(settings.pollInterval, 1) {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                    if engine.phase.isWarning { handle(engine.tick(at: .now)) }
                }
            }
        }
    }

    /// Deja de consultar la UPS y libera el USB.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        device.stop()
        history?.checkpoint()
    }

    // MARK: API

    /// Historial de los últimos `days` días.
    public func history(days: Int) -> HistorySnapshot {
        history?.snapshot(since: Date.now.addingTimeInterval(-Double(days) * 86_400)) ?? HistorySnapshot()
    }

    /// Borra el historial y, si se pide, el registro de texto.
    public func clearHistory(includeLogs: Bool) {
        history?.clear()
        if includeLogs { log.clear() }
        log.write(includeLogs ? "Historial y registro borrados por el usuario" : "Historial borrado por el usuario")
    }

    /// Primer uso del historial: reconstruirlo a partir de los registros de texto.
    private func importHistoryIfNeeded() {
        guard let history, history.isNew else { return }
        let texts = importLogs.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        let lines = LogImporter.lines(fromLogs: texts)
        history.importLines(lines)
        log.write("Historial creado; \(lines.count) registros importados de \(texts.count) archivos de registro")
    }

    public func snapshot(since eventID: Int) -> MonitorSnapshot {
        MonitorSnapshot(
            status: status,
            link: link,
            phase: engine.phase,
            lastUpdate: lastUpdate,
            protocolVariant: protocolVariant,
            lastError: lastError,
            beeperSyncing: beeperSyncing,
            beeperSyncError: beeperSyncError,
            settings: settings,
            events: eventID < 0 ? [] : events.filter { $0.id > eventID },
            lastEventID: nextEventID - 1,
            logPath: log.url.path
        )
    }

    public func update(settings new: MonitorSettings) {
        let firstSettings = !beeperEnforced
        beeperEnforced = true
        guard new != settings || firstSettings else { return }
        let beeperChanged = new.beeperEnabled != settings.beeperEnabled || firstSettings
        settings = new
        engine.policy = new.policy
        let p = new.policy
        log.write("Ajustes: batería baja UPS=\(p.onUPSLowBattery ? "sí" : "no") mín=\(p.minBatteryPercent)% "
            + "máx=\(p.maxMinutesOnBattery) min aviso=\(p.warningSeconds) s consulta=\(new.pollInterval) s "
            + "alarma=\(new.beeperEnabled ? "activada" : "silenciada")")
        if beeperChanged {
            beeperAttempts = 0
            Task { await syncBeeper(force: true) }
        }
    }

    public func postpone(minutes: Int) {
        handle(engine.postpone(minutes: minutes, at: .now))
    }

    public func shutdownNow() {
        handle(engine.shutdownImmediately(at: .now))
    }

    // MARK: Consulta

    func pollOnce() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        engine.policy = settings.policy
        do {
            let s = try await device.status()
            status = s
            lastUpdate = .now
            lastError = nil
            link = .connected
            logReading(s)
            handle(engine.ingest(s, at: .now))
            history?.ingest(s, at: .now)
            if beeperEnforced && s.beeperOn != settings.beeperEnabled { await syncBeeper() }
        } catch {
            lastError = String(describing: error)
            handle(engine.ingestFailure(at: .now))
        }
    }

    private func connectionChanged(_ connected: Bool) async {
        log.write(connected ? "UPS conectada por USB" : "UPS desconectada del USB")
        guard connected else { return }
        beeperAttempts = 0   // al reconectar, volver a aplicar la configuración
        if protocolVariant == nil { protocolVariant = try? await device.protocolVariant() }
        await pollOnce()
    }

    /// La alarma sonora sigue el ajuste: se aplica al iniciar, al reconectar la UPS,
    /// al cambiar el ajuste y si la UPS vuelve a otro estado. Tras
    /// `maxBeeperAttempts` intentos fallidos se deja de insistir hasta el próximo
    /// cambio de ajuste o reconexión, para no quedar alternando.
    func syncBeeper(force: Bool = false) async {
        guard beeperEnforced else { return }
        let want = settings.beeperEnabled
        if want != beeperTarget {
            beeperTarget = want
            beeperAttempts = 0
        }
        guard !beeperSyncing, beeperAttempts < Self.maxBeeperAttempts else { return }
        if !force, let s = status, s.beeperOn == want { return }

        beeperSyncing = true
        defer { beeperSyncing = false }
        beeperAttempts += 1
        let label = want ? "activada" : "desactivada"
        do {
            let before = status?.beeperOn
            let now = try await device.setBeeper(enabled: want)
            status?.beeperOn = now
            if now == want {
                if before != now { log.write("Alarma sonora \(label) según los ajustes") }
                beeperAttempts = 0
                beeperSyncError = nil
            } else if beeperAttempts >= Self.maxBeeperAttempts {
                beeperSyncError = "La UPS no aceptó el cambio de alarma"
                log.write("ERROR: la UPS no aceptó dejar la alarma \(label)")
            }
        } catch {
            if beeperAttempts >= Self.maxBeeperAttempts {
                beeperSyncError = String(describing: error)
                log.write("ERROR al ajustar la alarma sonora: \(error)")
            }
        }
    }

    private func logReading(_ s: UPSStatus) {
        // Cada 60 s con luz; en cada consulta durante un corte (sirve para calibrar la curva).
        guard s.onBattery || Date.now.timeIntervalSince(lastReadingLogged) >= 60 else { return }
        lastReadingLogged = .now
        log.write(String(
            format: "LECTURA ent=%.1fV sal=%.1fV carga=%d%% bat=%.2fV (%d%%) frec=%.1fHz bits=%@",
            s.inputVoltage, s.outputVoltage, s.loadPercent, s.batteryVoltage, s.batteryPercent,
            s.frequency, s.statusBitsString
        ))
    }

    // MARK: Eventos

    private func record(_ event: CoreEvent) {
        events.append(RecordedEvent(id: nextEventID, date: .now, event: event))
        nextEventID += 1
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
    }

    private func handle(_ monitorEvents: [MonitorEvent]) {
        for event in monitorEvents {
            switch event {
            case .outageConfirmed(let since):
                history?.outageStarted(at: since)
                log.write("CORTE de luz confirmado")
            case .powerRestored(let duration, let cancelled):
                history?.outageEnded(at: .now)
                log.write("VOLVIÓ la luz tras \(duration.durationText)" + (cancelled ? " (apagado cancelado)" : ""))
            case .warningStarted(let reason, let deadline):
                log.write("AVISO de apagado en \(Int(deadline.timeIntervalSinceNow.rounded())) s: \(reason)")
            case .warningAborted:
                log.write("Aviso de apagado suspendido: sin comunicación con la UPS")
            case .postponed(let until):
                log.write("Apagado pospuesto hasta \(until.formatted(date: .omitted, time: .shortened))")
            case .shutdownNow(let reason):
                history?.shutdown(reason: reason, at: .now)
                log.write("APAGANDO la Mac: \(reason)")
            case .communicationLost:
                if link == .connected { link = .lost }
                log.write("SIN COMUNICACIÓN con la UPS: \(lastError ?? "?")")
            case .communicationRestored:
                log.write("Comunicación con la UPS restablecida")
            }
            record(.monitor(event))
            if case .shutdownNow(let reason) = event { followUpShutdown(reason) }
        }
    }

    private func followUpShutdown(_ reason: ShutdownReason) {
        switch forced {
        case .unavailable(let retryAfter):
            Task {
                try? await Task.sleep(for: .seconds(retryAfter))
                guard case .shuttingDown = engine.phase else { return }
                log.write("El apagado no se completó; se volverá a avisar")
                engine.shutdownDidNotComplete()
                history?.shutdownCancelled()
                record(.shutdownIncomplete)
            }
        case .available(let grace, let hasActiveClient, let execute):
            guard hasActiveClient() else {
                log.write("Sin app conectada: apagado forzado")
                record(.shutdownForced(reason: reason))
                execute(reason)
                return
            }
            log.write("Apagado ordenado a cargo de la app; se forzará en \(Int(grace)) s si no se completa")
            Task {
                try? await Task.sleep(for: .seconds(grace))
                guard case .shuttingDown = engine.phase else { return }
                log.write("El apagado ordenado no se completó: apagado forzado")
                record(.shutdownForced(reason: reason))
                execute(reason)
            }
        }
    }
}
