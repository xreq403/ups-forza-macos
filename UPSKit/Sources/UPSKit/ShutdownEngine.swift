import Foundation

/// Umbrales de la política de apagado. Un valor 0 desactiva el umbral.
public struct ShutdownPolicy: Codable, Equatable, Sendable {
    /// Apagar cuando la UPS indique batería baja (b6).
    public var onUPSLowBattery = true
    /// Apagar cuando la batería estimada baje de este %.
    public var minBatteryPercent = 30
    /// Apagar tras estos minutos seguidos sin luz.
    public var maxMinutesOnBattery = 10
    /// Segundos de aviso antes de apagar.
    public var warningSeconds = 60
    /// Lecturas consecutivas necesarias para confirmar un corte o una pérdida de comunicación.
    public var debounceReadings = 2

    public init() {}

    // Decodificación tolerante a versiones anteriores (campos faltantes = valor por defecto).
    private enum CodingKeys: String, CodingKey {
        case onUPSLowBattery, minBatteryPercent, maxMinutesOnBattery, warningSeconds, debounceReadings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShutdownPolicy()
        onUPSLowBattery = try c.decodeIfPresent(Bool.self, forKey: .onUPSLowBattery) ?? d.onUPSLowBattery
        minBatteryPercent = try c.decodeIfPresent(Int.self, forKey: .minBatteryPercent) ?? d.minBatteryPercent
        maxMinutesOnBattery = try c.decodeIfPresent(Int.self, forKey: .maxMinutesOnBattery) ?? d.maxMinutesOnBattery
        warningSeconds = try c.decodeIfPresent(Int.self, forKey: .warningSeconds) ?? d.warningSeconds
        debounceReadings = try c.decodeIfPresent(Int.self, forKey: .debounceReadings) ?? d.debounceReadings
    }
}

public enum ShutdownReason: Codable, Equatable, Sendable, CustomStringConvertible {
    case upsBatteryLow
    case batteryBelow(percent: Int, threshold: Int)
    case timeOnBattery(minutes: Int)
    case user

    public var description: String {
        switch self {
        case .upsBatteryLow: "La UPS indica batería baja"
        case .batteryBelow(let p, let t): "Batería estimada en \(p) % (mínimo \(t) %)"
        case .timeOnBattery(let m): "\(m) min seguidos sin luz"
        case .user: "Apagado solicitado por el usuario"
        }
    }
}

public enum PowerPhase: Codable, Equatable, Sendable {
    /// Todavía sin lecturas.
    case unknown
    case online
    case onBattery(since: Date)
    /// Cuenta regresiva para apagar la Mac.
    case warning(since: Date, deadline: Date, reason: ShutdownReason)
    /// Se ordenó el apagado.
    case shuttingDown(since: Date, reason: ShutdownReason)

    public var outageStart: Date? {
        switch self {
        case .onBattery(let since), .warning(let since, _, _), .shuttingDown(let since, _): since
        case .unknown, .online: nil
        }
    }

    public var isWarning: Bool {
        if case .warning = self { true } else { false }
    }
}

public enum MonitorEvent: Codable, Equatable, Sendable {
    case outageConfirmed(since: Date)
    case powerRestored(outageDuration: TimeInterval, shutdownCancelled: Bool)
    case warningStarted(reason: ShutdownReason, deadline: Date)
    /// Se perdió la comunicación durante el aviso: no se apaga.
    case warningAborted
    case postponed(until: Date)
    case shutdownNow(reason: ShutdownReason)
    case communicationLost
    case communicationRestored
}

/// Máquina de estados de la política de apagado. Pura: no hace E/S, recibe
/// lecturas y el reloj, y devuelve eventos para que la app actúe.
public struct ShutdownEngine: Sendable {
    public var policy: ShutdownPolicy
    public private(set) var phase: PowerPhase = .unknown
    /// `nil` hasta el primer intento de lectura.
    public private(set) var communicating: Bool?

    private var onBatteryStreak = 0
    private var failureStreak = 0
    private var firstOnBatteryAt: Date?
    private var snoozedUntil: Date?

    public init(policy: ShutdownPolicy = ShutdownPolicy()) {
        self.policy = policy
    }

    private var debounce: Int { max(policy.debounceReadings, 1) }

    /// Procesa una lectura correcta de la UPS.
    public mutating func ingest(_ s: UPSStatus, at now: Date) -> [MonitorEvent] {
        var events: [MonitorEvent] = []
        failureStreak = 0
        if communicating == false { events.append(.communicationRestored) }
        communicating = true

        guard s.onBattery else {
            onBatteryStreak = 0
            firstOnBatteryAt = nil
            snoozedUntil = nil
            if let since = phase.outageStart {
                let cancelled: Bool = switch phase {
                case .warning, .shuttingDown: true
                default: false
                }
                events.append(.powerRestored(outageDuration: now.timeIntervalSince(since), shutdownCancelled: cancelled))
            }
            phase = .online
            return events
        }

        if case .shuttingDown = phase { return events }

        onBatteryStreak += 1
        if firstOnBatteryAt == nil { firstOnBatteryAt = now }

        switch phase {
        case .unknown, .online:
            // El bit de batería baja confirma el corte sin esperar el antirrebote.
            guard onBatteryStreak >= debounce || s.batteryLow else { return events }
            let since = firstOnBatteryAt ?? now
            phase = .onBattery(since: since)
            events.append(.outageConfirmed(since: since))
        default:
            break
        }

        if case .onBattery(let since) = phase, let reason = trigger(s, since: since, now: now) {
            let snoozed = snoozedUntil.map { now < $0 } ?? false
            if !snoozed || reason == .upsBatteryLow {
                let deadline = now.addingTimeInterval(TimeInterval(max(policy.warningSeconds, 0)))
                phase = .warning(since: since, deadline: deadline, reason: reason)
                events.append(.warningStarted(reason: reason, deadline: deadline))
            }
        }

        events += tick(at: now)
        return events
    }

    /// Procesa un fallo de comunicación con la UPS. Nunca dispara un apagado.
    public mutating func ingestFailure(at now: Date) -> [MonitorEvent] {
        failureStreak += 1
        guard communicating != false, failureStreak >= debounce else { return [] }
        communicating = false
        var events: [MonitorEvent] = [.communicationLost]
        if case .warning(let since, _, _) = phase {
            phase = .onBattery(since: since)
            events.append(.warningAborted)
        }
        return events
    }

    /// Avanza el reloj durante el aviso; al llegar al plazo ordena el apagado.
    public mutating func tick(at now: Date) -> [MonitorEvent] {
        guard case .warning(let since, let deadline, let reason) = phase, now >= deadline else { return [] }
        phase = .shuttingDown(since: since, reason: reason)
        return [.shutdownNow(reason: reason)]
    }

    /// El usuario pospone el apagado. No se permite si la UPS indica batería baja.
    public mutating func postpone(minutes: Int, at now: Date) -> [MonitorEvent] {
        guard case .warning(let since, _, let reason) = phase, reason != .upsBatteryLow else { return [] }
        let until = now.addingTimeInterval(TimeInterval(minutes * 60))
        snoozedUntil = until
        phase = .onBattery(since: since)
        return [.postponed(until: until)]
    }

    /// El usuario pide apagar ya (desde el aviso o durante un corte).
    public mutating func shutdownImmediately(at now: Date) -> [MonitorEvent] {
        let reason: ShutdownReason
        switch phase {
        case .warning(_, _, let r): reason = r
        case .onBattery: reason = .user
        default: return []
        }
        phase = .shuttingDown(since: phase.outageStart ?? now, reason: reason)
        return [.shutdownNow(reason: reason)]
    }

    /// El apagado no se completó (alguna app lo bloqueó): se vuelve a evaluar
    /// en la próxima lectura, lo que reabre el aviso si sigue sin luz.
    public mutating func shutdownDidNotComplete() {
        guard case .shuttingDown(let since, _) = phase else { return }
        snoozedUntil = nil
        phase = .onBattery(since: since)
    }

    private func trigger(_ s: UPSStatus, since: Date, now: Date) -> ShutdownReason? {
        if policy.onUPSLowBattery && s.batteryLow {
            return .upsBatteryLow
        }
        if policy.minBatteryPercent > 0 && s.batteryPercent < policy.minBatteryPercent {
            return .batteryBelow(percent: s.batteryPercent, threshold: policy.minBatteryPercent)
        }
        if policy.maxMinutesOnBattery > 0 && now.timeIntervalSince(since) >= TimeInterval(policy.maxMinutesOnBattery * 60) {
            return .timeOnBattery(minutes: policy.maxMinutesOnBattery)
        }
        return nil
    }
}
