import AppKit
import Observation
import UPSKit

/// Consulta la UPS periódicamente, aplica la política de apagado y actúa sobre
/// sus eventos: notificaciones, log, aviso de apagado y apagado de la Mac.
@MainActor @Observable
final class UPSMonitor {
    enum Link: Equatable {
        case searching   // nunca se conectó desde que arrancó la app
        case connected
        case lost
    }

    private(set) var status: UPSStatus?
    private(set) var link: Link = .searching
    private(set) var phase: PowerPhase = .unknown
    private(set) var lastUpdate: Date?
    private(set) var protocolVariant: String?
    private(set) var lastError: String?
    private(set) var policy = AppSettings.policy
    /// Error al aplicar el ajuste de alarma sonora, si la UPS no obedeció.
    private(set) var beeperSyncError: String?
    /// Se está enviando el cambio de alarma a la UPS.
    private(set) var beeperSyncing = false

    /// Alarma sonora deseada. Se guarda en los ajustes y se aplica a la UPS.
    var beeperEnabled: Bool = AppSettings.beeperEnabled {
        didSet {
            guard beeperEnabled != oldValue else { return }
            UserDefaults.standard.set(beeperEnabled, forKey: SettingsKey.beeperEnabled)
            beeperAttempts = 0
            Task { await syncBeeper(force: true) }
        }
    }

    @ObservationIgnored private let ups = ForzaUPS()
    @ObservationIgnored private var engine = ShutdownEngine()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private let log = EventLog.shared
    @ObservationIgnored private let warningPanel = ShutdownWarningPanel()
    @ObservationIgnored private var lastReadingLogged = Date.distantPast
    @ObservationIgnored private var beeperTarget: Bool?
    @ObservationIgnored private var beeperAttempts = 0
    private static let maxBeeperAttempts = 3

    func start() {
        guard pollTask == nil else { return }
        notifier.requestAuthorization()
        log.write("Inicio de UPS Forza")
        ups.transport.onConnectionChange = { connected in
            Task { @MainActor in self.connectionChanged(connected) }
        }
        ups.start()
        pollTask = Task {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: .seconds(AppSettings.pollInterval))
            }
        }
    }

    // MARK: - Acciones del usuario

    func postpone(minutes: Int = 5) {
        handle(engine.postpone(minutes: minutes, at: .now))
    }

    func shutdownNow() {
        handle(engine.shutdownImmediately(at: .now))
    }

    func sendTestNotification() {
        notifier.post("UPS Forza", "Las notificaciones funcionan. Así se verán los avisos de corte de luz.")
    }

    var canPostpone: Bool {
        if case .warning(_, _, let reason) = phase { reason != .upsBatteryLow } else { false }
    }

    // MARK: - Consulta

    private func poll() async {
        policy = AppSettings.policy
        engine.policy = policy
        do {
            let s = try await ups.status()
            status = s
            lastUpdate = .now
            lastError = nil
            link = .connected
            logReading(s)
            handle(engine.ingest(s, at: .now))
            if s.beeperOn != beeperEnabled { await syncBeeper() }
        } catch {
            lastError = String(describing: error)
            handle(engine.ingestFailure(at: .now))
        }
        phase = engine.phase
    }

    private func connectionChanged(_ connected: Bool) {
        log.write(connected ? "UPS conectada por USB" : "UPS desconectada del USB")
        guard connected else { return }
        beeperAttempts = 0   // al reconectar, volver a aplicar la configuración
        Task {
            if protocolVariant == nil { protocolVariant = try? await ups.protocolVariant() }
            await poll()
        }
    }

    /// La alarma sonora sigue el ajuste: se aplica al iniciar, al reconectar la UPS,
    /// al cambiar el ajuste y si la UPS vuelve a otro estado. Tras
    /// `maxBeeperAttempts` intentos fallidos se deja de insistir hasta el próximo
    /// cambio de ajuste o reconexión, para no quedar alternando.
    private func syncBeeper(force: Bool = false) async {
        let want = beeperEnabled
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
            let now = try await ups.setBeeper(enabled: want)
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

    // MARK: - Eventos

    private func handle(_ events: [MonitorEvent]) {
        for event in events {
            switch event {
            case .outageConfirmed:
                log.write("CORTE de luz confirmado")
                notifier.post("Corte de luz", "La Mac está funcionando con la batería de la UPS.")

            case .powerRestored(let duration, let cancelled):
                log.write("VOLVIÓ la luz tras \(duration.durationText)" + (cancelled ? " (apagado cancelado)" : ""))
                warningPanel.close()
                notifier.post("Volvió la luz", "El corte duró \(duration.durationText)."
                    + (cancelled ? " Se canceló el apagado." : ""))

            case .warningStarted(let reason, let deadline):
                let secs = Int(deadline.timeIntervalSinceNow.rounded())
                log.write("AVISO de apagado en \(secs) s: \(reason)")
                notifier.post("La Mac se apagará en \(secs) s", "\(reason). Guarda tu trabajo.", urgent: true)
                warningPanel.show(monitor: self)
                startTicking()

            case .warningAborted:
                log.write("Aviso de apagado suspendido: sin comunicación con la UPS")
                warningPanel.close()

            case .postponed(let until):
                log.write("Apagado pospuesto hasta \(until.formatted(date: .omitted, time: .shortened))")
                warningPanel.close()

            case .shutdownNow(let reason):
                warningPanel.close()
                performShutdown(reason)

            case .communicationLost:
                link = link == .searching ? .searching : .lost
                log.write("SIN COMUNICACIÓN con la UPS: \(lastError ?? "?")")
                notifier.post(
                    link == .searching ? "UPS no detectada" : "Sin comunicación con la UPS",
                    "Revisa el cable USB o el dock. La Mac no se apagará mientras no haya datos."
                )

            case .communicationRestored:
                log.write("Comunicación con la UPS restablecida")
                notifier.post("UPS conectada", "Se restableció la comunicación con la UPS.")
            }
        }
        phase = engine.phase
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task {
            while engine.phase.isWarning && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                handle(engine.tick(at: .now))
            }
        }
    }

    private func performShutdown(_ reason: ShutdownReason) {
        log.write("APAGANDO la Mac: \(reason)")
        do {
            try SystemShutdown.shutDown()
        } catch {
            log.write("ERROR al ordenar el apagado: \(error)")
            notifier.post("No se pudo apagar la Mac", String(describing: error), urgent: true)
        }
        // Si en 2 min seguimos vivos, alguna app bloqueó el apagado: volver a avisar.
        Task {
            try? await Task.sleep(for: .seconds(120))
            guard case .shuttingDown = engine.phase else { return }
            log.write("El apagado no se completó; se volverá a avisar")
            engine.shutdownDidNotComplete()
            phase = engine.phase
        }
    }
}
