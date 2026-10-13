import Foundation

/// Rango de la serie temporal del panel.
public enum SeriesRange: Int, Codable, Sendable, CaseIterable {
    case hour1 = 60
    case hours6 = 360
    case hours24 = 1440

    public var minutes: Int { rawValue }
}

/// Un punto de la serie: una lectura (última hora) o un agregado de varias.
/// Durante un corte la entrada no tiene sentido (≈ 8,5 V residuales): queda `nil`.
public struct SeriesPoint: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { time }
    public let time: Date
    public var inputMin: Double?
    public var inputAvg: Double?
    public var inputMax: Double?
    public var outputAvg: Double
    public var batteryMin: Double
    public var batteryAvg: Double
    public var loadAvg: Double
    public var loadMax: Int
    /// Hubo al menos una lectura en batería en el intervalo.
    public var onBattery: Bool
    /// El AVR estuvo activo en algún momento del intervalo.
    public var avr: Bool

    /// Consumo promedio estimado en W.
    public var watts: Double { loadAvg * Double(UPSStatus.ratedWatts) / 100 }
}

/// Serie temporal de lecturas para el panel en vivo:
/// - última hora: cada lectura;
/// - últimas 24 h: agregados por minuto, guardados en disco para sobrevivir a reinicios.
/// No es thread-safe: la usa `MonitorCore` desde su actor.
final class SeriesStore {
    private let url: URL?
    private var raw: [SeriesPoint] = []
    private var minutes: [SeriesPoint] = []
    /// Lecturas del minuto en curso.
    private var current: [UPSStatus] = []
    private var currentMinute: Date?
    private var lastSave = Date.now
    static let saveInterval: TimeInterval = 300

    init(url: URL?) {
        self.url = url
        load()
    }

    func add(_ s: UPSStatus, at date: Date) {
        raw.append(Self.point([s], at: date))
        let hourAgo = date.addingTimeInterval(-3600)
        if let i = raw.firstIndex(where: { $0.time >= hourAgo }), i > 0 { raw.removeFirst(i) }

        let minute = Self.minuteStart(date)
        if let m = currentMinute, m != minute { closeMinute(m) }
        currentMinute = minute
        current.append(s)

        if date.timeIntervalSince(lastSave) >= Self.saveInterval { save(at: date) }
    }

    func series(_ range: SeriesRange, now: Date = .now) -> [SeriesPoint] {
        let since = now.addingTimeInterval(-Double(range.minutes) * 60)
        switch range {
        case .hour1:
            return raw.filter { $0.time >= since }
        case .hours6:
            return withCurrentMinute().filter { $0.time >= since }
        case .hours24:
            // Bloques de 5 min: 288 puntos.
            return Self.bucket(withCurrentMinute().filter { $0.time >= since }, seconds: 300)
        }
    }

    func save(at date: Date = .now) {
        lastSave = date
        guard let url else { return }
        let cutoff = date.addingTimeInterval(-86_400)
        minutes.removeAll { $0.time < cutoff }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(minutes).write(to: url, options: .atomic)
    }

    // MARK: Agregación

    private func closeMinute(_ minute: Date) {
        guard !current.isEmpty else { return }
        minutes.append(Self.point(current, at: minute))
        current = []
        let cutoff = minute.addingTimeInterval(-86_400)
        if let i = minutes.firstIndex(where: { $0.time >= cutoff }), i > 0 { minutes.removeFirst(i) }
    }

    private func withCurrentMinute() -> [SeriesPoint] {
        guard let m = currentMinute, !current.isEmpty else { return minutes }
        return minutes + [Self.point(current, at: m)]
    }

    static func point(_ readings: [UPSStatus], at time: Date) -> SeriesPoint {
        let inputs = readings.filter { !$0.onBattery }.map(\.inputVoltage)
        let n = Double(readings.count)
        return SeriesPoint(
            time: time,
            inputMin: inputs.min(),
            inputAvg: inputs.isEmpty ? nil : inputs.reduce(0, +) / Double(inputs.count),
            inputMax: inputs.max(),
            outputAvg: readings.map(\.outputVoltage).reduce(0, +) / n,
            batteryMin: readings.map(\.batteryVoltage).min() ?? 0,
            batteryAvg: readings.map(\.batteryVoltage).reduce(0, +) / n,
            loadAvg: Double(readings.map(\.loadPercent).reduce(0, +)) / n,
            loadMax: readings.map(\.loadPercent).max() ?? 0,
            onBattery: readings.contains { $0.onBattery },
            avr: readings.contains { $0.avrActive && !$0.onBattery }
        )
    }

    /// Agrupa puntos en bloques de `seconds`.
    static func bucket(_ points: [SeriesPoint], seconds: TimeInterval) -> [SeriesPoint] {
        var groups: [Date: [SeriesPoint]] = [:]
        for p in points {
            let key = Date(timeIntervalSince1970: (p.time.timeIntervalSince1970 / seconds).rounded(.down) * seconds)
            groups[key, default: []].append(p)
        }
        return groups.keys.sorted().map { key in
            let g = groups[key]!
            let inputs = g.compactMap(\.inputAvg)
            let n = Double(g.count)
            return SeriesPoint(
                time: key,
                inputMin: g.compactMap(\.inputMin).min(),
                inputAvg: inputs.isEmpty ? nil : inputs.reduce(0, +) / Double(inputs.count),
                inputMax: g.compactMap(\.inputMax).max(),
                outputAvg: g.map(\.outputAvg).reduce(0, +) / n,
                batteryMin: g.map(\.batteryMin).min() ?? 0,
                batteryAvg: g.map(\.batteryAvg).reduce(0, +) / n,
                loadAvg: g.map(\.loadAvg).reduce(0, +) / n,
                loadMax: g.map(\.loadMax).max() ?? 0,
                onBattery: g.contains { $0.onBattery },
                avr: g.contains { $0.avr }
            )
        }
    }

    static func minuteStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([SeriesPoint].self, from: data) else { return }
        let cutoff = Date.now.addingTimeInterval(-86_400)
        minutes = saved.filter { $0.time >= cutoff }.sorted { $0.time < $1.time }
    }
}
