import Foundation

// MARK: - Modelo

/// Una lectura durante la descarga de calibración.
public struct CalibrationSample: Codable, Sendable, Equatable {
    /// Segundos desde que la UPS pasó a batería.
    public let t: TimeInterval
    public let volts: Double
    public let load: Int

    public init(t: TimeInterval, volts: Double, load: Int) {
        self.t = t
        self.volts = volts
        self.load = load
    }

    public var minutes: Double { t / 60 }
}

/// Por qué terminó la descarga.
public enum CalibrationStopReason: String, Codable, Sendable {
    /// Llegó al voltaje mínimo seguro.
    case targetVoltage
    /// Se cumplió la duración máxima elegida.
    case timeLimit
    /// La UPS indicó batería baja (b6).
    case upsLowBattery
    /// Volvió la luz (la UPS se enchufó antes de terminar).
    case powerRestored
    case cancelled

    public var description: String {
        switch self {
        case .targetVoltage: "Llegó al voltaje mínimo seguro"
        case .timeLimit: "Se cumplió la duración máxima"
        case .upsLowBattery: "La UPS indicó batería baja"
        case .powerRestored: "Se volvió a enchufar la UPS"
        case .cancelled: "Detenida por el usuario"
        }
    }
}

/// Resultado de una prueba de descarga: cómo baja el voltaje con el consumo real.
///
/// No mide la capacidad total (para eso habría que agotar la batería), pero da la
/// pendiente del voltaje con ese consumo, que es lo que necesita la estimación de
/// autonomía.
public struct CalibrationRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    /// Momento en que la UPS pasó a batería.
    public let start: Date
    /// Fin de la descarga (no de la espera a que vuelva la luz).
    public var end: Date
    /// Voltaje con el cargador, antes de desenchufar.
    public var voltageBefore: Double
    public var samples: [CalibrationSample]
    public var stopReason: CalibrationStopReason
    /// Voltaje mínimo seguro configurado para esta prueba.
    public var floorVoltage: Double

    public init(id: UUID = UUID(), start: Date, end: Date, voltageBefore: Double,
                samples: [CalibrationSample], stopReason: CalibrationStopReason,
                floorVoltage: Double = Calibration.floorVoltage) {
        self.id = id
        self.start = start
        self.end = end
        self.voltageBefore = voltageBefore
        self.samples = samples
        self.stopReason = stopReason
        self.floorVoltage = floorVoltage
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var voltageMin: Double { samples.map(\.volts).min() ?? voltageBefore }

    public var averageLoad: Double {
        samples.isEmpty ? 0 : Double(samples.map(\.load).reduce(0, +)) / Double(samples.count)
    }

    public var averageWatts: Double { averageLoad * Double(UPSStatus.ratedWatts) / 100 }

    /// Pendiente de la descarga (V/min, positiva) y voltaje "asentado", ajustados
    /// por mínimos cuadrados sobre las lecturas posteriores a la caída inicial.
    public var fit: Calibration.Fit? { Calibration.fit(samples) }

    /// Minutos que tardaría la batería, llena y con este consumo, en llegar a `volts`.
    /// Extrapolación lineal: al final de la descarga el voltaje cae más rápido, así
    /// que es optimista lejos de lo medido.
    public func projectedMinutes(to volts: Double) -> Double? {
        guard let fit, fit.slope > 0 else { return nil }
        return max((fit.intercept - volts) / fit.slope, 0)
    }

    /// Sirve para estimar la autonomía: suficientes minutos medidos tras la caída inicial.
    public var isUsable: Bool { fit != nil }
}

public enum Calibration {
    /// Voltaje mínimo seguro: ~30 % según la curva orientativa. La prueba se detiene aquí.
    public static let floorVoltage = 23.6
    /// Lecturas seguidas por debajo del mínimo para detenerla (evita picos).
    static let floorReadings = 2
    /// La caída inicial (se pierde el voltaje del cargador) dura ~1–2 min: no cuenta para la pendiente.
    public static let settleSeconds: TimeInterval = 120
    /// Minutos de datos posteriores a la caída inicial para calcular la pendiente.
    public static let minFitSeconds: TimeInterval = 300
    /// Tiempo para desenchufar la UPS tras iniciar la prueba.
    public static let unplugTimeout: TimeInterval = 300
    public static let durationOptions = [15, 30, 60, 90]

    public struct Fit: Sendable, Equatable {
        /// Caída en V por minuto (positiva si el voltaje baja).
        public let slope: Double
        /// Voltaje extrapolado a t = 0 sobre la recta (batería llena, ya sin cargador).
        public let intercept: Double
    }

    public static func fit(_ samples: [CalibrationSample]) -> Fit? {
        let pts = samples.filter { $0.t >= settleSeconds }
        guard let first = pts.first, let last = pts.last, last.t - first.t >= minFitSeconds, pts.count >= 5 else { return nil }
        let n = Double(pts.count)
        let mx = pts.map(\.minutes).reduce(0, +) / n
        let my = pts.map(\.volts).reduce(0, +) / n
        let sxx = pts.map { ($0.minutes - mx) * ($0.minutes - mx) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let sxy = pts.map { ($0.minutes - mx) * ($0.volts - my) }.reduce(0, +)
        let b = sxy / sxx
        return Fit(slope: -b, intercept: my - b * mx)
    }
}

// MARK: - Estado en curso (viaja en el snapshot)

public enum CalibrationPhase: Codable, Sendable, Equatable {
    /// Esperando que el usuario desenchufe la UPS.
    case waitingForUnplug(deadline: Date)
    /// En batería, registrando lecturas.
    case discharging(start: Date, deadline: Date)
    /// La descarga terminó; esperando que vuelva la luz para guardar el resultado.
    case waitingForPower(start: Date, stopped: Date, reason: CalibrationStopReason)
}

public struct CalibrationState: Codable, Sendable, Equatable {
    public var phase: CalibrationPhase
    public var maxMinutes: Int
    public var voltageBefore: Double
    public var samples: [CalibrationSample]

    public init(phase: CalibrationPhase, maxMinutes: Int, voltageBefore: Double, samples: [CalibrationSample] = []) {
        self.phase = phase
        self.maxMinutes = maxMinutes
        self.voltageBefore = voltageBefore
        self.samples = samples
    }

    /// Durante la descarga se suspenden los umbrales de % y de tiempo de la política
    /// (siguen el de batería baja de la UPS y el voltaje mínimo de la prueba).
    var suspendsSoftThresholds: Bool {
        switch phase {
        case .waitingForUnplug, .discharging: true
        case .waitingForPower: false
        }
    }
}

/// Respuesta a iniciar una calibración: `nil` si arrancó, o por qué no.
public struct CalibrationResponse: Codable, Sendable {
    public var error: String?
    public init(error: String? = nil) { self.error = error }
}

// MARK: - Autonomía durante un corte

/// Minutos que quedan durante un corte, según la última calibración.
public struct AutonomyEstimate: Codable, Sendable, Equatable {
    /// Minutos hasta que la batería llegue a `limitVolts`.
    public var batteryMinutes: Double
    /// Voltaje límite: el del % mínimo de la política o, si está desactivado, el mínimo seguro.
    public var limitVolts: Double
    /// Minutos hasta que la política apague la Mac (por % o por tiempo), si algún umbral aplica.
    public var shutdownMinutes: Double?
    /// Consumo promedio del corte, en W.
    public var watts: Double

    /// Lo que se muestra: hasta el apagado si hay umbral, si no hasta el límite.
    public var minutes: Double { shutdownMinutes ?? batteryMinutes }
}

public enum Autonomy {
    /// Extrapola la pendiente de la calibración, escalada por el consumo actual
    /// (con más consumo el voltaje baja en proporción). Durante la caída inicial el
    /// voltaje todavía no refleja la carga: se toma como mucho el de batería llena.
    public static func estimate(volts: Double, averageLoad: Double, elapsed: TimeInterval,
                                calibration: CalibrationRecord, policy: ShutdownPolicy) -> AutonomyEstimate? {
        guard let fit = calibration.fit, fit.slope > 0 else { return nil }
        let ratio = max(averageLoad, 1) / max(calibration.averageLoad, 1)
        let slope = fit.slope * ratio
        let limit = policy.minBatteryPercent > 0
            ? BatteryEstimator.volts(forPercent: Double(policy.minBatteryPercent))
            : Calibration.floorVoltage
        let effective = min(volts, fit.intercept)
        let battery = max(effective - limit, 0) / slope

        var shutdown: [Double] = []
        if policy.minBatteryPercent > 0 { shutdown.append(battery) }
        if policy.maxMinutesOnBattery > 0 {
            shutdown.append(max(Double(policy.maxMinutesOnBattery) * 60 - elapsed, 0) / 60)
        }
        return AutonomyEstimate(batteryMinutes: battery, limitVolts: limit, shutdownMinutes: shutdown.min(),
                                watts: averageLoad * Double(UPSStatus.ratedWatts) / 100)
    }
}
