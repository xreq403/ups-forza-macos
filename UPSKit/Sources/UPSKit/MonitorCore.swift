import Foundation

// MARK: - Dispositivo

/// Lo que `MonitorCore` necesita de la UPS. `ForzaUPS` lo implementa; los tests usan uno simulado.
public protocol UPSDevice: Sendable {
    func start(onConnectionChange: @escaping @Sendable (Bool) -> Void)
    func stop()
    func status() async throws -> UPSStatus
    func protocolVariant() async throws -> String
    func setBeeper(enabled: Bool) async throws -> Bool
    /// `T`: test rápido de batería (~6 s alimentando desde la batería).
    func startBatteryTest() async throws
}

extension ForzaUPS: UPSDevice {
    public func start(onConnectionChange: @escaping @Sendable (Bool) -> Void) {
        transport.onConnectionChange = onConnectionChange
        start()
    }

    public func stop() {
        transport.stop()
    }

    public func startBatteryTest() async throws {
        try await batteryTest()
    }

}

// MARK: - Modelo compartido con la app (también viaja por XPC como JSON)

public struct MonitorSettings: Codable, Sendable, Equatable {
    public var pollInterval = 5
    public var policy = ShutdownPolicy()
    public var beeperEnabled = true
    /// Test de batería automático cada N días (0 = desactivado).
    public var batteryTestIntervalDays = 0

    public init() {}

    // Decodificación tolerante: un settings.json de una versión anterior (sin los
    // campos nuevos) tiene que seguir leyéndose, no volver a los valores por defecto.
    private enum CodingKeys: String, CodingKey {
        case pollInterval, policy, beeperEnabled, batteryTestIntervalDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MonitorSettings()
        pollInterval = try c.decodeIfPresent(Int.self, forKey: .pollInterval) ?? d.pollInterval
        policy = try c.decodeIfPresent(ShutdownPolicy.self, forKey: .policy) ?? d.policy
        beeperEnabled = try c.decodeIfPresent(Bool.self, forKey: .beeperEnabled) ?? d.beeperEnabled
        batteryTestIntervalDays = try c.decodeIfPresent(Int.self, forKey: .batteryTestIntervalDays)
            ?? d.batteryTestIntervalDays
    }
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
    /// Terminó un test de batería (manual o automático).
    case batteryTestFinished(BatteryTestRecord)
    /// La descarga de calibración terminó: hay que volver a enchufar la UPS.
    case calibrationStopped(CalibrationStopReason)
    /// Volvió la luz y se guardó el resultado de la calibración.
    case calibrationFinished(CalibrationRecord)
    /// No se desenchufó la UPS a tiempo: la calibración se canceló.
    case calibrationAbandoned
}

/// Respuesta a un pedido de test de batería: el resultado, o por qué no se hizo.
public struct BatteryTestResponse: Codable, Sendable {
    public var record: BatteryTestRecord?
    public var error: String?

    public init(record: BatteryTestRecord? = nil, error: String? = nil) {
        self.record = record
        self.error = error
    }
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
    public var batteryTestRunning: Bool
    public var lastBatteryTest: BatteryTestRecord?
    /// Calibración en curso.
    public var calibration: CalibrationState?
    public var lastCalibration: CalibrationRecord?
    /// Minutos que quedan durante un corte (con una calibración válida).
    public var autonomy: AutonomyEstimate?
    /// Recarga en curso tras un corte.
    public var recharge: RechargeEstimate?
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
    private let series: SeriesStore
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
        importLogs: [URL] = [],
        seriesURL: URL? = nil
    ) {
        self.series = SeriesStore(url: seriesURL)
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
                await runScheduledBatteryTestIfDue()
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
        series.save()
    }

    // MARK: API

    /// Serie temporal de lecturas para el panel en vivo.
    public func series(_ range: SeriesRange) -> [SeriesPoint] {
        series.series(range)
    }

    /// Historial de los últimos `days` días.
    public func history(days: Int) -> HistorySnapshot {
        history?.snapshot(since: Date.now.addingTimeInterval(-Double(days) * 86_400)) ?? HistorySnapshot()
    }

    /// Borra el historial y, si se pide, el registro de texto.
    /// Fusiona el historial de otro monitor (JSONL), p. ej. el de la app en modo local.
    public func mergeHistory(_ data: Data) -> Int {
        guard let history else { return 0 }
        let n = history.merge(jsonl: data)
        log.write("Historial: \(n) registros fusionados desde la app")
        return n
    }

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
            logPath: log.url.path,
            batteryTestRunning: batteryTestRunning,
            lastBatteryTest: lastBatteryTest ?? history?.lastBatteryTest,
            calibration: calibration,
            lastCalibration: lastCalibration ?? history?.lastCalibration,
            autonomy: autonomy(),
            recharge: rechargeEstimate
        )
    }

    /// Consumo promedio del corte en curso (suaviza el % que informa la UPS).
    private var outageLoad: (sum: Int, count: Int) = (0, 0)

    private func autonomy() -> AutonomyEstimate? {
        guard let s = status, s.onBattery, calibration == nil, outageLoad.count > 0,
              let cal = [lastCalibration, history?.lastUsableCalibration].compactMap({ $0 }).filter(\.isUsable)
                .max(by: { $0.start < $1.start })
        else { return nil }
        let elapsed = engine.phase.outageStart.map { Date.now.timeIntervalSince($0) } ?? 0
        return Autonomy.estimate(volts: s.batteryVoltage, averageLoad: Double(outageLoad.sum) / Double(outageLoad.count),
                                 elapsed: elapsed, calibration: cal, policy: settings.policy)
    }

    public func update(settings new: MonitorSettings) {
        let firstSettings = !beeperEnforced
        beeperEnforced = true
        guard new != settings || firstSettings else { return }
        let beeperChanged = new.beeperEnabled != settings.beeperEnabled || firstSettings
        settings = new
        engine.policy = effectivePolicy
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
        engine.policy = effectivePolicy
        do {
            var s = try await device.status()
            trackRecharge(&s, at: .now)
            status = s
            lastUpdate = .now
            lastError = nil
            link = .connected
            if s.onBattery { onlineSince = nil } else if onlineSince == nil { onlineSince = .now }
            logReading(s)
            handle(engine.ingest(s, at: .now))
            calibrationStep(s, at: .now)
            outageLoad = s.onBattery ? (outageLoad.sum + s.loadPercent, outageLoad.count + 1) : (0, 0)
            history?.ingest(s, at: .now)
            series.add(s, at: .now)
            if beeperEnforced && s.beeperOn != settings.beeperEnabled { await syncBeeper() }
        } catch {
            lastError = String(describing: error)
            onlineSince = nil
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

    // MARK: Test de batería

    private var batteryTestRunning = false
    private var lastBatteryTest: BatteryTestRecord?
    /// Desde cuándo hay luz y comunicación sin interrupciones (para el test automático).
    private var onlineSince: Date?
    private var lastScheduledAttempt: Date?
    /// Minutos con luz estable antes de un test automático.
    static let scheduledTestStableOnline: TimeInterval = 600

    /// Test rápido de batería (`T`): la UPS alimenta ~6 s desde la batería (bit b2).
    /// Mide el voltaje mínimo y lo compara con el primer test superado (referencia).
    /// Solo con luz, comunicación y sin otro test o apagado en curso.
    public func runBatteryTest(trigger: BatteryTestTrigger) async -> BatteryTestResponse {
        guard link == .connected, let s = status else { return BatteryTestResponse(error: "La UPS no está conectada.") }
        guard !s.onBattery else { return BatteryTestResponse(error: "Hay un corte de luz en curso.") }
        guard case .online = engine.phase else { return BatteryTestResponse(error: "La UPS no está en funcionamiento normal con luz.") }
        guard !batteryTestRunning, !s.testInProgress else { return BatteryTestResponse(error: "Ya hay un test en curso.") }
        guard calibration == nil else { return BatteryTestResponse(error: "Hay una calibración en curso.") }
        batteryTestRunning = true
        defer { batteryTestRunning = false }

        let start = Date.now
        var rec = BatteryTestRecord(start: start, trigger: trigger, voltageBefore: s.batteryVoltage,
                                    voltageMin: s.batteryVoltage, maxLoadPercent: s.loadPercent)
        log.write("TEST de batería (\(trigger == .manual ? "manual" : "automático")): T")
        do {
            try await device.startBatteryTest()
        } catch {
            log.write("ERROR enviando T: \(error)")
            return BatteryTestResponse(error: "No se pudo enviar el test: \(error)")
        }

        var sawTest = false, low = false, fault = false
        while Date.now.timeIntervalSince(start) < 30 {
            try? await Task.sleep(for: .seconds(1))
            guard let r = try? await device.status() else { continue }
            status = r
            if r.onBattery { break }   // corte real: lo maneja el monitor
            if r.testInProgress {
                if !sawTest { rec.voltageMin = r.batteryVoltage }
                sawTest = true
                rec.voltageMin = min(rec.voltageMin, r.batteryVoltage)
                rec.maxLoadPercent = max(rec.maxLoadPercent, r.loadPercent)
                low = low || r.batteryLow
                fault = fault || r.upsFault
            } else if sawTest || Date.now.timeIntervalSince(start) > 5 {
                break   // terminó, o la UPS no lo inició
            }
        }

        rec.duration = Date.now.timeIntervalSince(start)
        rec.outcome = !sawTest ? .notStarted : (low || fault ? .failed : .passed)
        let reference = history?.referenceBatteryTest
        rec.health = BatteryTestRecord.health(outcome: rec.outcome, voltageMin: rec.voltageMin,
                                              load: rec.maxLoadPercent, reference: reference)
        rec.referenceVoltage = reference?.voltageMin
        history?.record(batteryTest: rec)
        lastBatteryTest = rec
        log.write(String(format: "TEST de batería: %@ · mín %.2f V (antes %.2f V, caída %.2f V) · consumo %d%% · salud %@",
                         rec.outcome.rawValue, rec.voltageMin, rec.voltageBefore, rec.drop,
                         rec.maxLoadPercent, rec.health.rawValue))
        record(.batteryTestFinished(rec))
        return BatteryTestResponse(record: rec)
    }

    /// Test automático: cada `batteryTestIntervalDays` días, con al menos 10 min de luz
    /// estable. Un intento fallido no se repite hasta el próximo intervalo.
    private func runScheduledBatteryTestIfDue() async {
        let days = settings.batteryTestIntervalDays
        guard days > 0, calibration == nil, let since = onlineSince,
              Date.now.timeIntervalSince(since) >= Self.scheduledTestStableOnline else { return }
        let last = [history?.lastBatteryTest?.start, lastScheduledAttempt].compactMap { $0 }.max()
        if let last, Date.now.timeIntervalSince(last) < Double(days) * 86_400 { return }
        lastScheduledAttempt = .now
        _ = await runBatteryTest(trigger: .scheduled)
    }

    // MARK: Recarga

    private var rechargeTracker = RechargeTracker()
    private var rechargeSeeded = false
    private var rechargeRate: (percentPerHour: Double, measured: Bool) = (Recharge.defaultPercentPerHour, false)

    /// Con luz el % por voltaje siempre da 100 (lo impone el cargador): tras un corte
    /// se estima la recarga hasta que el voltaje se estabiliza en flotación, y cada
    /// recarga completa se guarda para medir el ritmo real del cargador.
    private func trackRecharge(_ s: inout UPSStatus, at now: Date) {
        if !rechargeSeeded {
            rechargeSeeded = true
            rechargeRate = Recharge.rate(from: history?.recharges ?? [])
            // Tras reiniciar el monitor, retomar la recarga del último corte si no terminó.
            if let last = history?.lastFinishedOutage, now.timeIntervalSince(last.end) < 86_400,
               !(history?.recharges.contains { $0.start >= last.end.addingTimeInterval(-60) } ?? false) {
                rechargeTracker.resume(percent: last.minPercent, since: last.end)
            }
        }
        guard let done = rechargeTracker.ingest(&s, at: now, rate: rechargeRate) else { return }
        history?.record(recharge: done)
        rechargeRate = Recharge.rate(from: history?.recharges ?? [done])
        log.write(String(format: "RECARGA completa: %d %% → 100 %% en %@ (%.1f %%/h). Ritmo del cargador: %.1f %%/h%@",
                         done.startPercent, done.duration.durationText, done.percentPerHour,
                         rechargeRate.percentPerHour, rechargeRate.measured ? "" : " (típico)"))
    }

    /// Recarga en curso para la interfaz.
    private var rechargeEstimate: RechargeEstimate? {
        guard let a = rechargeTracker.active, status?.onBattery == false else { return nil }
        return RechargeEstimate(startPercent: a.percent, since: a.since,
                                percentPerHour: rechargeRate.percentPerHour, measured: rechargeRate.measured)
    }

    // MARK: Calibración

    private var calibration: CalibrationState?
    private var lastCalibration: CalibrationRecord?

    /// Política aplicada: durante la descarga de calibración se suspenden los umbrales
    /// de % y de tiempo (el usuario está presente y la prueba se detiene en el voltaje
    /// mínimo). La batería baja de la UPS sigue apagando la Mac.
    private var effectivePolicy: ShutdownPolicy {
        var p = settings.policy
        if calibration?.suspendsSoftThresholds == true {
            p.minBatteryPercent = 0
            p.maxMinutesOnBattery = 0
        }
        return p
    }

    /// Inicia una prueba de descarga: el usuario desenchufa la UPS, se registran las
    /// lecturas hasta el voltaje mínimo o `maxMinutes`, y al volver la luz se guarda.
    public func startCalibration(maxMinutes: Int) -> CalibrationResponse {
        guard link == .connected, let s = status else { return CalibrationResponse(error: "La UPS no está conectada.") }
        guard !s.onBattery, case .online = engine.phase else { return CalibrationResponse(error: "Hay un corte de luz en curso.") }
        guard calibration == nil else { return CalibrationResponse(error: "Ya hay una calibración en curso.") }
        guard !batteryTestRunning, !s.testInProgress else { return CalibrationResponse(error: "Hay un test de batería en curso.") }
        guard !s.charging else {
            return CalibrationResponse(error: String(format: "La batería todavía se está recargando (%.2f V). Espera a que llegue a %.1f V.",
                                                     s.batteryVoltage, BatteryEstimator.floatVoltage))
        }
        let minutes = min(max(maxMinutes, 5), 180)
        calibration = CalibrationState(phase: .waitingForUnplug(deadline: .now.addingTimeInterval(Calibration.unplugTimeout)),
                                       maxMinutes: minutes, voltageBefore: s.batteryVoltage)
        log.write(String(format: "CALIBRACIÓN iniciada: máx. %d min, mínimo %.1f V, batería %.2f V. Esperando que se desenchufe la UPS",
                         minutes, Calibration.floorVoltage, s.batteryVoltage))
        return CalibrationResponse()
    }

    /// Detiene la prueba. Si la UPS ya estaba en batería, el resultado se guarda al volver la luz.
    public func cancelCalibration() {
        guard let c = calibration else { return }
        switch c.phase {
        case .waitingForUnplug:
            calibration = nil
            log.write("CALIBRACIÓN cancelada antes de desenchufar")
        case .discharging(let start, _):
            stopDischarge(start: start, reason: .cancelled, at: .now)
        case .waitingForPower:
            finishCalibration(at: .now)
        }
    }

    private func calibrationStep(_ s: UPSStatus, at now: Date) {
        guard var c = calibration else { return }
        switch c.phase {
        case .waitingForUnplug(let deadline):
            if s.onBattery {
                c.phase = .discharging(start: now, deadline: now.addingTimeInterval(Double(c.maxMinutes) * 60))
                c.samples = [CalibrationSample(t: 0, volts: s.batteryVoltage, load: s.loadPercent)]
                calibration = c
                log.write("CALIBRACIÓN: UPS en batería, registrando la descarga")
            } else if now >= deadline {
                calibration = nil
                log.write("CALIBRACIÓN cancelada: no se desenchufó la UPS a tiempo")
                record(.calibrationAbandoned)
            }

        case .discharging(let start, let deadline):
            guard s.onBattery else {
                // Se enchufó antes de terminar (o volvió la luz): se guarda lo medido.
                c.phase = .waitingForPower(start: start, stopped: now, reason: .powerRestored)
                calibration = c
                finishCalibration(at: now)
                return
            }
            c.samples.append(CalibrationSample(t: now.timeIntervalSince(start), volts: s.batteryVoltage, load: s.loadPercent))
            calibration = c
            let below = c.samples.suffix(Calibration.floorReadings)
            let reachedFloor = below.count == Calibration.floorReadings && below.allSatisfy { $0.volts <= Calibration.floorVoltage }
            if s.batteryLow { stopDischarge(start: start, reason: .upsLowBattery, at: now) }
            else if reachedFloor { stopDischarge(start: start, reason: .targetVoltage, at: now) }
            else if now >= deadline { stopDischarge(start: start, reason: .timeLimit, at: now) }

        case .waitingForPower:
            if !s.onBattery { finishCalibration(at: now) }
        }
    }

    private func stopDischarge(start: Date, reason: CalibrationStopReason, at now: Date) {
        guard var c = calibration else { return }
        c.phase = .waitingForPower(start: start, stopped: now, reason: reason)
        calibration = c
        engine.policy = effectivePolicy   // vuelven los umbrales de la política
        log.write(String(format: "CALIBRACIÓN: descarga terminada (%@) a los %@, batería %.2f V. Volver a enchufar la UPS",
                         reason.description, now.timeIntervalSince(start).durationText, c.samples.last?.volts ?? 0))
        record(.calibrationStopped(reason))
    }

    private func finishCalibration(at now: Date) {
        guard let c = calibration, case .waitingForPower(let start, let stopped, let reason) = c.phase else { return }
        calibration = nil
        let rec = CalibrationRecord(start: start, end: stopped, voltageBefore: c.voltageBefore,
                                    samples: c.samples, stopReason: reason)
        history?.record(calibration: rec)
        lastCalibration = rec
        if let fit = rec.fit {
            log.write(String(format: "CALIBRACIÓN guardada: %@, %d lecturas, %.2f→%.2f V, %.4f V/min con ~%.0f W",
                             rec.duration.durationText, rec.samples.count, rec.samples.first?.volts ?? 0,
                             rec.voltageMin, fit.slope, rec.averageWatts))
        } else {
            log.write("CALIBRACIÓN guardada: \(rec.duration.durationText), datos insuficientes para la pendiente")
        }
        record(.calibrationFinished(rec))
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
                let calibrating = calibration != nil
                history?.outageStarted(at: since, calibration: calibrating)
                log.write(calibrating ? "CORTE de luz confirmado (desenchufe de la calibración)" : "CORTE de luz confirmado")
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
