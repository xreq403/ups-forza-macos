import Foundation

/// Una recarga medida: desde que volvió la luz hasta que el cargador llegó a flotación.
public struct RechargeRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Cuando volvió la luz.
    public let start: Date
    /// Cuando el voltaje se estabilizó en flotación (batería llena).
    public var end: Date
    /// % estimado al terminar el corte.
    public var startPercent: Int

    public init(id: UUID = UUID(), start: Date, end: Date, startPercent: Int) {
        self.id = id
        self.start = start
        self.end = end
        self.startPercent = startPercent
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Ritmo promedio de la recarga en % por hora.
    public var percentPerHour: Double {
        Double(100 - startPercent) / max(duration / 3600, 1.0 / 60)
    }

    /// Sirve para medir el cargador: descarga apreciable y recarga de al menos 20 min
    /// (las recargas cortas tras descargas mínimas dan ritmos poco representativos).
    public var isUsable: Bool { startPercent <= 90 && duration >= 1200 }
}

/// Recarga en curso, para mostrar el % y el tiempo restante.
public struct RechargeEstimate: Codable, Sendable, Equatable {
    public var startPercent: Int
    public var since: Date
    public var percentPerHour: Double
    /// El ritmo sale de recargas medidas en esta UPS (si no, es el valor típico).
    public var measured: Bool

    /// Hasta que el cargador llega a flotación se informa como mucho 99 %.
    public func percent(at now: Date = .now) -> Int {
        let hours = max(now.timeIntervalSince(since), 0) / 3600
        return min(Int((Double(startPercent) + hours * percentPerHour).rounded()), 99)
    }

    public func minutesLeft(at now: Date = .now) -> Double {
        Double(100 - percent(at: now)) / percentPerHour * 60
    }
}

public enum Recharge {
    /// Ritmo típico si todavía no hay recargas medidas: ~90 % en 7–8 h.
    public static let defaultPercentPerHour = 12.0
    /// La batería está llena cuando el voltaje se mantiene en flotación: al menos
    /// `fullVoltage` durante `holdSeconds`, sin subir más de `maxRise` en ese lapso.
    /// (Flotación medida: 27,1–27,3 V. Durante la recarga el voltaje sube despacio.)
    public static let fullVoltage = 27.0
    public static let holdSeconds: TimeInterval = 600
    public static let maxRise = 0.03
    /// Recargas medidas que se promedian para el ritmo.
    static let samplesForRate = 3

    /// Ritmo del cargador: promedio de las últimas recargas usables, acotado a valores razonables.
    public static func rate(from records: [RechargeRecord]) -> (percentPerHour: Double, measured: Bool) {
        let usable = records.filter(\.isUsable).sorted { $0.start > $1.start }.prefix(samplesForRate)
        guard !usable.isEmpty else { return (defaultPercentPerHour, false) }
        let avg = usable.map(\.percentPerHour).reduce(0, +) / Double(usable.count)
        return (min(max(avg, 3), 60), true)
    }
}

/// Sigue la recarga tras un corte. Puro (recibe el reloj) para poder probarlo.
/// No es thread-safe: lo usa `MonitorCore` desde su actor.
struct RechargeTracker {
    /// % al terminar el corte y cuándo volvió la luz.
    private(set) var active: (percent: Int, since: Date)?
    private var lastOnBatteryPercent: Int?
    /// Lecturas recientes con el voltaje en flotación.
    private var window: [(date: Date, volts: Double)] = []

    /// Retoma una recarga que estaba en curso (p. ej. tras reiniciar el monitor).
    mutating func resume(percent: Int, since: Date) {
        active = (percent, since)
    }

    /// Procesa una lectura: ajusta el % y `charging` mientras dura la recarga.
    /// Devuelve la recarga terminada, si en esta lectura se llegó a flotación.
    mutating func ingest(_ s: inout UPSStatus, at now: Date,
                         rate: (percentPerHour: Double, measured: Bool)) -> RechargeRecord? {
        if s.onBattery {
            lastOnBatteryPercent = s.batteryPercent
            active = nil
            window = []
            return nil
        }
        if let p = lastOnBatteryPercent {
            // Un microcorte casi no descarga la batería: no inicia una recarga.
            if p < 98 { active = (p, now) }
            lastOnBatteryPercent = nil
            window = []
        }
        guard let a = active else { return nil }

        if s.batteryVoltage >= Recharge.fullVoltage {
            window.append((now, s.batteryVoltage))
            window.removeAll { now.timeIntervalSince($0.date) > Recharge.holdSeconds }
            if let first = window.first, let since = firstFloat, now.timeIntervalSince(since) >= Recharge.holdSeconds,
               s.batteryVoltage - first.volts <= Recharge.maxRise {
                active = nil
                window = []
                firstFloat = nil
                return RechargeRecord(start: a.since, end: now, startPercent: a.percent)
            }
            if firstFloat == nil { firstFloat = now }
        } else {
            window = []
            firstFloat = nil
        }

        let estimate = RechargeEstimate(startPercent: a.percent, since: a.since,
                                        percentPerHour: rate.percentPerHour, measured: rate.measured)
        s.charging = true
        s.batteryPercent = estimate.percent(at: now)
        return nil
    }

    /// Desde cuándo el voltaje está en flotación sin interrupciones.
    private var firstFloat: Date?
}
