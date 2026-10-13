import AppKit
import Observation
import UPSKit

/// Estado de la UPS para la interfaz. No habla con la UPS directamente: lo hace
/// un backend, que es el daemon root (si está activo) o un monitor local en la
/// propia app. Nunca los dos a la vez, para no competir por el USB.
///
/// La app reacciona a los eventos del monitor: notificaciones, panel de aviso y
/// apagado ordenado de la Mac (que tiene que hacerse desde la sesión del usuario).
@MainActor @Observable
final class UPSMonitor {
    enum BackendKind: Equatable {
        case none
        case local
        case daemon
    }

    private(set) var status: UPSStatus?
    private(set) var link: LinkState = .searching
    private(set) var phase: PowerPhase = .unknown
    private(set) var protocolVariant: String?
    private(set) var lastError: String?
    private(set) var beeperSyncError: String?
    private(set) var beeperSyncing = false
    private(set) var logURL = EventLog.userLogURL
    private(set) var backendKind: BackendKind = .none
    /// El daemon está activo pero no responde.
    private(set) var backendError: String?
    private(set) var batteryTestRunning = false
    private(set) var lastBatteryTest: BatteryTestRecord?
    /// Cambia al borrar el historial, para que las vistas lo recarguen.
    private(set) var historyRevision = 0

    /// Alarma sonora deseada. Se guarda en los ajustes y se envía al monitor.
    var beeperEnabled: Bool = AppSettings.beeperEnabled {
        didSet {
            guard beeperEnabled != oldValue else { return }
            UserDefaults.standard.set(beeperEnabled, forKey: SettingsKey.beeperEnabled)
            Task { await pushSettingsIfNeeded() }
        }
    }

    let daemon = DaemonController()

    @ObservationIgnored private var backend: MonitorBackend?
    /// Label del daemon en uso (puede ser el de la otra build, p. ej. la Release desde Xcode).
    @ObservationIgnored private var daemonLabelInUse: String?
    @ObservationIgnored private var daemonFailures = 0
    @ObservationIgnored private var lastProbe = Date.distantPast
    @ObservationIgnored private var lastEventID = -1
    @ObservationIgnored private var lastPushed: MonitorSettings?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private let warningPanel = ShutdownWarningPanel()

    func start() {
        guard loopTask == nil else { return }
        notifier.requestAuthorization()
        loopTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Acciones del usuario

    func postpone(minutes: Int = 5) {
        Task { try? await backend?.postpone(minutes: minutes); await refresh() }
    }

    func shutdownNow() {
        Task { try? await backend?.shutdownNow(); await refresh() }
    }

    /// Historial de los últimos `days` días desde el backend activo.
    func loadHistory(days: Int) async throws -> HistorySnapshot {
        guard let backend else { throw DaemonBackendError.noProxy }
        return try await backend.history(days: days)
    }

    /// Borra el historial del backend activo y, si se pide, también los registros
    /// de texto (el del backend y, con el daemon, el de la app en modo local).
    func clearHistory(includeLogs: Bool) async throws {
        guard let backend else { throw DaemonBackendError.noProxy }
        try await backend.clearHistory(includeLogs: includeLogs)
        if includeLogs && backendKind == .daemon { EventLog(url: EventLog.userLogURL).clear() }
        historyRevision += 1
    }

    /// Test rápido de batería. El resultado llega también como evento.
    func runBatteryTest() async -> BatteryTestResponse {
        guard let backend else { return BatteryTestResponse(error: "El monitor no está listo.") }
        batteryTestRunning = true
        do {
            let response = try await backend.runBatteryTest()
            if let record = response.record { lastBatteryTest = record }
            batteryTestRunning = false
            historyRevision += 1
            return response
        } catch {
            batteryTestRunning = false
            return BatteryTestResponse(error: String(describing: error))
        }
    }

    func loadSeries(_ range: SeriesRange) async throws -> [SeriesPoint] {
        guard let backend else { throw DaemonBackendError.noProxy }
        return try await backend.series(range)
    }

    func powerSettings() async throws -> SystemPowerSettings {
        guard let backend else { throw DaemonBackendError.noProxy }
        return try await backend.powerSettings()
    }

    func setAutoRestart(_ on: Bool) async throws {
        guard let backend else { throw DaemonBackendError.noProxy }
        try await backend.setAutoRestart(on)
    }

    func sendTestNotification() {
        notifier.post("UPS Forza", "Las notificaciones funcionan. Así se verán los avisos de corte de luz.")
    }

    var canPostpone: Bool {
        if case .warning(_, _, let reason) = phase { reason != .upsBatteryLow } else { false }
    }

    // MARK: - Ciclo

    private func refresh() async {
        // El estado del daemon puede cambiar desde Ajustes del Sistema: revisarlo cada 5 s.
        if ticks % 5 == 0 { daemon.refresh() }
        ticks += 1

        let (kind, label) = await chooseBackend()
        if kind != backendKind || label != daemonLabelInUse { await switchBackend(to: kind, label: label) }
        guard let backend else { return }

        await pushSettingsIfNeeded()
        do {
            apply(try await backend.snapshot(since: lastEventID))
            backendError = nil
            daemonFailures = 0
        } catch {
            backendError = String(describing: error)
            daemonFailures += 1
        }
    }

    /// Usa el daemon propio si está activo. Si no, el de la otra build si está
    /// corriendo (para no competir con él por el USB). Si no hay ninguno, el monitor local.
    private func chooseBackend() async -> (BackendKind, String?) {
        if daemon.isEnabled { return (.daemon, daemon.label) }
        if backendKind == .daemon, let label = daemonLabelInUse, label != daemon.label, daemonFailures < 3 {
            return (.daemon, label)
        }
        if backendKind != .local || Date.now.timeIntervalSince(lastProbe) >= 15 {
            lastProbe = .now
            for label in DaemonIdentity.allLabels where label != daemon.label {
                if await DaemonBackend.isReachable(label: label) { return (.daemon, label) }
            }
        }
        return (.local, nil)
    }

    private func switchBackend(to kind: BackendKind, label: String?) async {
        // Primero soltar el anterior: el monitor local libera el USB para el daemon.
        await backend?.stop()
        let new: MonitorBackend = if kind == .daemon, let label {
            DaemonBackend(label: label)
        } else {
            LocalBackend(settings: AppSettings.monitorSettings)
        }
        await new.start()
        backend = new
        backendKind = kind
        daemonLabelInUse = label
        daemonFailures = 0
        lastEventID = -1      // no repetir eventos viejos del nuevo backend
        lastPushed = nil      // enviarle los ajustes de esta app
        warningPanel.close()
        if let daemonBackend = new as? DaemonBackend { await mergeLocalHistory(into: daemonBackend) }
    }

    /// Lo registrado en modo local (cortes, AVR, tests de batería, incluida la
    /// referencia) pasa al historial del daemon. El archivo se renombra para no
    /// volver a enviarlo.
    private func mergeLocalHistory(into daemon: DaemonBackend) async {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: LocalHistory.url), !data.isEmpty else { return }
        do {
            _ = try await daemon.mergeHistory(data)
            try? fm.removeItem(at: LocalHistory.mergedURL)
            try fm.moveItem(at: LocalHistory.url, to: LocalHistory.mergedURL)
            historyRevision += 1
        } catch {
            backendError = "No se pudo pasar el historial local al servicio: \(error)"
        }
    }

    private func pushSettingsIfNeeded() async {
        guard let backend else { return }
        let current = AppSettings.monitorSettings
        guard current != lastPushed else { return }
        do {
            try await backend.update(settings: current)
            lastPushed = current
        } catch {
            backendError = String(describing: error)
        }
    }

    private func apply(_ snap: MonitorSnapshot) {
        status = snap.status
        link = snap.link
        phase = snap.phase
        protocolVariant = snap.protocolVariant
        lastError = snap.lastError
        beeperSyncing = snap.beeperSyncing
        beeperSyncError = snap.beeperSyncError
        logURL = URL(fileURLWithPath: snap.logPath)
        batteryTestRunning = snap.batteryTestRunning
        lastBatteryTest = snap.lastBatteryTest
        for recorded in snap.events { handle(recorded, link: snap.link) }
        lastEventID = snap.lastEventID
        if !phase.isWarning { warningPanel.close() }
    }

    // MARK: - Eventos

    private func handle(_ recorded: RecordedEvent, link: LinkState) {
        switch recorded.event {
        case .monitor(.outageConfirmed):
            notifier.post("Corte de luz", "La Mac está funcionando con la batería de la UPS.")

        case .monitor(.powerRestored(let duration, let cancelled)):
            warningPanel.close()
            notifier.post("Volvió la luz", "El corte duró \(duration.durationText)."
                + (cancelled ? " Se canceló el apagado." : ""))

        case .monitor(.warningStarted(let reason, let deadline)):
            let secs = max(Int(deadline.timeIntervalSinceNow.rounded()), 0)
            notifier.post("La Mac se apagará en \(secs) s", "\(reason). Guarda tu trabajo.", urgent: true)
            warningPanel.show(monitor: self)

        case .monitor(.warningAborted):
            warningPanel.close()
            notifier.post("Apagado suspendido", "Se perdió la comunicación con la UPS; la Mac no se apagará.")

        case .monitor(.postponed):
            warningPanel.close()

        case .monitor(.shutdownNow(let reason)):
            warningPanel.close()
            // Un evento viejo (la app estuvo suspendida) no debe apagar la Mac.
            guard Date.now.timeIntervalSince(recorded.date) < 60 else { return }
            performOrderedShutdown(reason)

        case .monitor(.communicationLost):
            notifier.post(
                link == .searching ? "UPS no detectada" : "Sin comunicación con la UPS",
                "Revisa el cable USB o el dock. La Mac no se apagará mientras no haya datos."
            )

        case .monitor(.communicationRestored):
            notifier.post("UPS conectada", "Se restableció la comunicación con la UPS.")

        case .shutdownIncomplete:
            notifier.post("La Mac no se apagó", "Alguna app bloqueó el apagado. Se volverá a avisar.", urgent: true)

        case .shutdownForced:
            notifier.post("Apagado forzado", "El apagado ordenado no se completó; el servicio apaga la Mac.", urgent: true)

        case .batteryTestFinished(let t):
            // Solo avisa si algo salió mal (el resultado normal se ve en el popover).
            switch (t.outcome, t.health) {
            case (.failed, _):
                notifier.post("Test de batería: falla", "La UPS indicó batería baja o falla durante el test. Conviene revisar o cambiar las baterías.", urgent: true)
            case (.passed, .degrading):
                notifier.post("Test de batería: desgaste",
                              String(format: "La batería cayó a %.2f V (referencia %.2f V). Se está desgastando.",
                                     t.voltageMin, t.referenceVoltage ?? 0))
            case (.notStarted, _) where t.trigger == .scheduled:
                notifier.post("Test de batería", "La UPS no inició el test automático.")
            default:
                break
            }
        }
    }

    /// Apagado ordenado desde la sesión del usuario (como "Apagar…" del menú Apple).
    /// Con el daemon activo, si no se completa, el daemon lo fuerza a los 90 s.
    private func performOrderedShutdown(_ reason: ShutdownReason) {
        do {
            try SystemShutdown.shutDown()
        } catch {
            notifier.post("No se pudo apagar la Mac", String(describing: error), urgent: true)
        }
    }
}
