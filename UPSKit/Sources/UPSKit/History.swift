import Foundation

// MARK: - Modelo

/// Un corte de luz: desde que se confirma hasta que vuelve la luz o se apaga la Mac.
public struct OutageRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var start: Date
    /// `nil` mientras dura el corte, o si quedó sin cerrar (el monitor se detuvo).
    public var end: Date?
    public var minBatteryVoltage: Double?
    public var minBatteryPercent: Int?
    public var maxLoadPercent: Int?
    /// Si el corte terminó con la Mac apagada por la app o el daemon.
    public var shutdownReason: ShutdownReason?
    /// Reconstruido a partir del registro de texto (datos aproximados).
    public var imported: Bool

    public init(id: UUID = UUID(), start: Date, end: Date? = nil, imported: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.imported = imported
    }

    mutating func include(_ s: UPSStatus) {
        minBatteryVoltage = min(minBatteryVoltage ?? .infinity, s.batteryVoltage)
        minBatteryPercent = min(minBatteryPercent ?? .max, s.batteryPercent)
        maxLoadPercent = max(maxLoadPercent ?? 0, s.loadPercent)
    }
}

/// Tipo de corrección del AVR. El firmware no lo informa: se deduce comparando
/// la salida con la entrada.
public enum AVRMode: String, Codable, Sendable {
    /// Reducción: la red está alta y la UPS baja la salida.
    case buck
    /// Elevación: la red está baja y la UPS sube la salida.
    case boost
    case unknown

    static func from(input: Double, output: Double) -> AVRMode {
        if output < input - 2 { return .buck }
        if output > input + 2 { return .boost }
        return .unknown
    }
}

/// Un período con el AVR activo (bit b5) mientras hay luz.
public struct AVRRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var start: Date
    public var end: Date?
    public var mode: AVRMode
    public var inputMin: Double
    public var inputMax: Double
    public var outputMin: Double
    public var outputMax: Double
    public var imported: Bool

    init(start: Date, status s: UPSStatus, imported: Bool = false) {
        id = UUID()
        self.start = start
        mode = AVRMode.from(input: s.inputVoltage, output: s.outputVoltage)
        inputMin = s.inputVoltage
        inputMax = s.inputVoltage
        outputMin = s.outputVoltage
        outputMax = s.outputVoltage
        self.imported = imported
    }

    mutating func include(_ s: UPSStatus) {
        inputMin = min(inputMin, s.inputVoltage)
        inputMax = max(inputMax, s.inputVoltage)
        outputMin = min(outputMin, s.outputVoltage)
        outputMax = max(outputMax, s.outputVoltage)
        if mode == .unknown { mode = AVRMode.from(input: s.inputVoltage, output: s.outputVoltage) }
    }
}

/// Voltaje de entrada de la red durante un día (solo con luz).
public struct DayStats: Codable, Sendable, Equatable {
    /// Día local, `yyyy-MM-dd`.
    public let day: String
    public var inputMin: Double
    public var inputMax: Double
    public var inputSum: Double
    public var samples: Int

    public var inputAverage: Double { samples > 0 ? inputSum / Double(samples) : 0 }

    init(day: String, input: Double) {
        self.day = day
        inputMin = input
        inputMax = input
        inputSum = input
        samples = 1
    }

    mutating func include(_ input: Double) {
        inputMin = min(inputMin, input)
        inputMax = max(inputMax, input)
        inputSum += input
        samples += 1
    }
}

/// Microcorte: lecturas en batería que no llegaron a confirmarse como corte
/// (la luz volvió antes de la segunda lectura). Mide la estabilidad de la red.
public struct MicroOutageRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let start: Date
    /// Primera lectura con luz después del microcorte (fin aproximado).
    public var end: Date
    /// Lecturas en batería (normalmente 1).
    public var readings: Int

    public init(id: UUID = UUID(), start: Date, end: Date, readings: Int = 1) {
        self.id = id
        self.start = start
        self.end = end
        self.readings = readings
    }
}

// MARK: - Test de batería

public enum BatteryTestTrigger: String, Codable, Sendable {
    case manual
    case scheduled
}

public enum BatteryTestOutcome: String, Codable, Sendable {
    /// La batería sostuvo la carga sin indicar batería baja ni falla.
    case passed
    /// La UPS indicó batería baja o falla durante el test.
    case failed
    /// La UPS no marcó el test (bit b2): no se hizo.
    case notStarted
}

/// Comparación con la referencia (el primer test superado).
public enum BatteryHealth: String, Codable, Sendable {
    /// Primer test superado: es la referencia.
    case reference
    case good
    /// Cayó claramente más que en la referencia: la batería se está desgastando.
    case degrading
    case bad
    case unknown
}

/// Resultado de un test rápido de batería (`T`): ~6 s alimentando desde la batería.
public struct BatteryTestRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let start: Date
    public var duration: TimeInterval
    public var trigger: BatteryTestTrigger
    public var outcome: BatteryTestOutcome
    /// Voltaje justo antes del test (con el cargador: no refleja la carga real).
    public var voltageBefore: Double
    /// Voltaje mínimo durante el test: el indicador de salud.
    public var voltageMin: Double
    public var maxLoadPercent: Int
    public var health: BatteryHealth
    /// Voltaje mínimo del test de referencia, si lo había.
    public var referenceVoltage: Double?

    public var drop: Double { voltageBefore - voltageMin }

    public init(id: UUID = UUID(), start: Date, duration: TimeInterval = 0, trigger: BatteryTestTrigger,
                outcome: BatteryTestOutcome = .notStarted, voltageBefore: Double, voltageMin: Double,
                maxLoadPercent: Int = 0, health: BatteryHealth = .unknown, referenceVoltage: Double? = nil) {
        self.id = id
        self.start = start
        self.duration = duration
        self.trigger = trigger
        self.outcome = outcome
        self.voltageBefore = voltageBefore
        self.voltageMin = voltageMin
        self.maxLoadPercent = maxLoadPercent
        self.health = health
        self.referenceVoltage = referenceVoltage
    }

    /// Margen respecto de la referencia a partir del cual se considera desgaste.
    public static let degradationMargin = 0.4

    /// Evalúa la salud comparando con la referencia. Solo compara si el consumo es
    /// parecido (±5 puntos), porque con más consumo el voltaje cae más.
    static func health(outcome: BatteryTestOutcome, voltageMin: Double, load: Int,
                       reference: BatteryTestRecord?) -> BatteryHealth {
        switch outcome {
        case .failed: return .bad
        case .notStarted: return .unknown
        case .passed: break
        }
        guard let reference else { return .reference }
        guard abs(load - reference.maxLoadPercent) <= 5 else { return .good }
        return voltageMin < reference.voltageMin - degradationMargin ? .degrading : .good
    }
}

/// Una línea del archivo de historial. Un mismo id (o día) puede aparecer varias
/// veces: al cargar, la última versión gana.
public enum HistoryLine: Codable, Sendable, Equatable {
    case outage(OutageRecord)
    case avr(AVRRecord)
    case day(DayStats)
    case batteryTest(BatteryTestRecord)
    case microOutage(MicroOutageRecord)
}

public struct HistorySnapshot: Codable, Sendable {
    public var outages: [OutageRecord]
    public var avr: [AVRRecord]
    public var days: [DayStats]
    public var batteryTests: [BatteryTestRecord]
    public var microOutages: [MicroOutageRecord]
    /// Episodios en curso (los demás sin `end` quedaron sin cerrar).
    public var currentOutageID: UUID?
    public var currentAVRID: UUID?

    public init(outages: [OutageRecord] = [], avr: [AVRRecord] = [], days: [DayStats] = [],
                batteryTests: [BatteryTestRecord] = [], microOutages: [MicroOutageRecord] = [],
                currentOutageID: UUID? = nil, currentAVRID: UUID? = nil) {
        self.outages = outages
        self.avr = avr
        self.days = days
        self.batteryTests = batteryTests
        self.microOutages = microOutages
        self.currentOutageID = currentOutageID
        self.currentAVRID = currentAVRID
    }
}

// MARK: - Almacenamiento

/// Historial en un archivo JSONL de solo agregar: cada cambio relevante agrega una
/// línea, así resiste crashes y apagados forzados. Al cargar se compacta (última
/// versión de cada episodio) y se descarta lo más viejo que `retentionDays`.
/// No es thread-safe: lo usa `MonitorCore` desde su actor.
final class HistoryStore {
    let url: URL
    /// El archivo no existía (primer uso): conviene importar los registros de texto.
    let isNew: Bool
    static let retentionDays = 365
    static let checkpointInterval: TimeInterval = 600

    private var outages: [UUID: OutageRecord] = [:]
    private var avr: [UUID: AVRRecord] = [:]
    private var days: [String: DayStats] = [:]
    private var batteryTests: [UUID: BatteryTestRecord] = [:]
    private var microOutages: [UUID: MicroOutageRecord] = [:]
    /// Lecturas en batería todavía no confirmadas como corte.
    private var pendingMicro: (start: Date, readings: Int)?
    private var currentOutageID: UUID?
    private var currentAVRID: UUID?
    private var lastCheckpoint = Date.now
    private var lastDayKey: String?

    init(url: URL) {
        self.url = url
        isNew = !FileManager.default.fileExists(atPath: url.path)
        load()
    }

    // MARK: Eventos del monitor

    func outageStarted(at start: Date) {
        guard currentOutageID == nil else { return }   // ya hay uno abierto
        pendingMicro = nil                             // se confirmó: no es un microcorte
        let record = OutageRecord(start: start)
        currentOutageID = record.id
        outages[record.id] = record
        append(.outage(record))
    }

    func outageEnded(at end: Date) {
        guard let id = currentOutageID, var record = outages[id] else { return }
        record.end = end
        outages[id] = record
        currentOutageID = nil
        append(.outage(record))
    }

    /// Se ordenó apagar la Mac: el corte termina aquí (la escritura es inmediata).
    func shutdown(reason: ShutdownReason, at date: Date) {
        guard let id = currentOutageID, var record = outages[id] else { return }
        record.shutdownReason = reason
        record.end = date
        outages[id] = record
        append(.outage(record))
    }

    /// El apagado no se completó: el corte sigue abierto.
    func shutdownCancelled() {
        guard let id = currentOutageID, var record = outages[id] else { return }
        record.end = nil
        record.shutdownReason = nil
        outages[id] = record
        append(.outage(record))
    }

    /// Cada lectura correcta de la UPS.
    func ingest(_ s: UPSStatus, at date: Date) {
        if let id = currentOutageID { outages[id]?.include(s) }

        // Microcortes: lecturas en batería sin corte confirmado. Si vuelve la luz
        // antes de la confirmación, quedan registradas como microcorte.
        if currentOutageID == nil {
            if s.onBattery {
                pendingMicro = (pendingMicro?.start ?? date, (pendingMicro?.readings ?? 0) + 1)
            } else if let pending = pendingMicro {
                let m = MicroOutageRecord(start: pending.start, end: date, readings: pending.readings)
                microOutages[m.id] = m
                pendingMicro = nil
                append(.microOutage(m))
            }
        }

        // AVR: solo con luz.
        let avrOn = s.avrActive && !s.onBattery
        if avrOn {
            if let id = currentAVRID {
                avr[id]?.include(s)
            } else {
                let record = AVRRecord(start: date, status: s)
                currentAVRID = record.id
                avr[record.id] = record
                append(.avr(record))
            }
        } else if let id = currentAVRID, var record = avr[id] {
            record.end = date
            avr[id] = record
            currentAVRID = nil
            append(.avr(record))
        }

        // Voltaje de la red del día (con luz y lecturas razonables).
        let key = Self.dayKey(date)
        if !s.onBattery && s.inputVoltage > 50 {
            if days[key] == nil { days[key] = DayStats(day: key, input: s.inputVoltage) } else { days[key]?.include(s.inputVoltage) }
        }
        if let last = lastDayKey, last != key, let stats = days[last] { append(.day(stats)) }
        lastDayKey = key

        if date.timeIntervalSince(lastCheckpoint) >= Self.checkpointInterval { checkpoint(at: date) }
    }

    /// Guarda el estado en curso (mínimos del corte, AVR abierto, día actual).
    func checkpoint(at date: Date = .now) {
        lastCheckpoint = date
        if let id = currentOutageID, let r = outages[id] { append(.outage(r)) }
        if let id = currentAVRID, let r = avr[id] { append(.avr(r)) }
        if let stats = days[Self.dayKey(date)] { append(.day(stats)) }
    }

    /// Borra todo el historial. El archivo queda vacío (no se vuelve a importar).
    func clear() {
        outages = [:]
        avr = [:]
        days = [:]
        batteryTests = [:]
        microOutages = [:]
        pendingMicro = nil
        currentOutageID = nil
        currentAVRID = nil
        lastDayKey = nil
        rewrite()
    }

    func record(batteryTest t: BatteryTestRecord) {
        batteryTests[t.id] = t
        append(.batteryTest(t))
    }

    /// Primer test superado: la referencia de salud.
    var referenceBatteryTest: BatteryTestRecord? {
        batteryTests.values.filter { $0.outcome == .passed }.min { $0.start < $1.start }
    }

    var lastBatteryTest: BatteryTestRecord? {
        batteryTests.values.max { $0.start < $1.start }
    }

    /// Fusiona un archivo de historial (JSONL) de otro monitor, p. ej. el de la app
    /// en modo local. Los episodios con el mismo id no se duplican.
    /// Devuelve cuántas líneas válidas tenía.
    @discardableResult
    func merge(jsonl data: Data) -> Int {
        let decoder = JSONDecoder()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            try? decoder.decode(HistoryLine.self, from: Data($0.utf8))
        }
        for line in lines {
            // Un día que ya existe: los dos monitores suelen partir de la misma copia,
            // así que sumar contaría dos veces. Se queda la versión con más muestras.
            if case .day(let incoming) = line, let existing = days[incoming.day] {
                if incoming.samples > existing.samples { days[incoming.day] = incoming }
            } else {
                apply(line)
            }
        }
        rewrite()
        return lines.count
    }

    func importLines(_ lines: [HistoryLine]) {
        for line in lines { apply(line) }
        rewrite()
    }

    func snapshot(since: Date) -> HistorySnapshot {
        let sinceKey = Self.dayKey(since)
        return HistorySnapshot(
            outages: outages.values.filter { ($0.end ?? .now) >= since }.sorted { $0.start > $1.start },
            avr: avr.values.filter { ($0.end ?? .now) >= since }.sorted { $0.start > $1.start },
            days: days.values.filter { $0.day >= sinceKey }.sorted { $0.day > $1.day },
            batteryTests: batteryTests.values.filter { $0.start >= since }.sorted { $0.start > $1.start },
            microOutages: microOutages.values.filter { $0.end >= since }.sorted { $0.start > $1.start },
            currentOutageID: currentOutageID,
            currentAVRID: currentAVRID
        )
    }

    // MARK: Archivo

    private func apply(_ line: HistoryLine) {
        switch line {
        case .outage(let r): outages[r.id] = r
        case .avr(let r): avr[r.id] = r
        case .day(let d): days[d.day] = d
        case .batteryTest(let t): batteryTests[t.id] = t
        case .microOutage(let m): microOutages[m.id] = m
        }
    }

    private func load() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        for raw in text.split(separator: "\n") {
            if let line = try? decoder.decode(HistoryLine.self, from: Data(raw.utf8)) { apply(line) }
        }
        rewrite()
    }

    /// Reescribe el archivo compactado, sin lo anterior a la retención.
    private func rewrite() {
        let cutoff = Date.now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        let cutoffKey = Self.dayKey(cutoff)
        outages = outages.filter { ($0.value.end ?? $0.value.start) >= cutoff }
        microOutages = microOutages.filter { $0.value.end >= cutoff }
        // Los tests se conservan siempre: el de referencia puede tener años.

        avr = avr.filter { ($0.value.end ?? $0.value.start) >= cutoff }
        days = days.filter { $0.key >= cutoffKey }

        var lines: [HistoryLine] = []
        lines += outages.values.sorted { $0.start < $1.start }.map(HistoryLine.outage)
        lines += avr.values.sorted { $0.start < $1.start }.map(HistoryLine.avr)
        lines += days.values.sorted { $0.day < $1.day }.map(HistoryLine.day)
        lines += batteryTests.values.sorted { $0.start < $1.start }.map(HistoryLine.batteryTest)
        lines += microOutages.values.sorted { $0.start < $1.start }.map(HistoryLine.microOutage)
        let encoder = JSONEncoder()
        let data = lines.compactMap { try? encoder.encode($0) }
            .reduce(into: Data()) { $0 += $1; $0 += Data("\n".utf8) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func append(_ line: HistoryLine) {
        guard var data = try? JSONEncoder().encode(line) else { return }
        data += Data("\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - Resumen por día

public struct DaySummary: Sendable, Equatable, Identifiable {
    public var id: String { day }
    /// Día local, `yyyy-MM-dd`.
    public let day: String
    public let date: Date
    public var outages = 0
    public var outageSeconds: TimeInterval = 0
    public var microOutages = 0
    public var avrCount = 0
    public var avrSeconds: TimeInterval = 0
    public var inputMin: Double?
    public var inputMax: Double?
    public var inputAverage: Double?
}

public enum HistorySummary {
    /// Un resumen por día de los últimos `days` días (el más reciente primero).
    /// Las duraciones se recortan a cada día; un episodio en curso cuenta hasta `now`,
    /// y uno sin cerrar cuenta solo su inicio.
    public static func daily(_ snap: HistorySnapshot, days: Int, now: Date = .now,
                             calendar: Calendar = .current) -> [DaySummary] {
        let today = calendar.startOfDay(for: now)
        var result: [DaySummary] = []
        let stats = Dictionary(snap.days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })

        for offset in 0..<max(days, 1) {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            let key = HistoryStore.dayKey(start)
            var s = DaySummary(day: key, date: start)

            for o in snap.outages {
                let oEnd = o.end ?? (o.id == snap.currentOutageID ? now : o.start)
                let overlap = min(oEnd, end).timeIntervalSince(max(o.start, start))
                if o.start >= start && o.start < end { s.outages += 1 }
                if overlap > 0 { s.outageSeconds += overlap }
            }
            s.microOutages = snap.microOutages.filter { $0.start >= start && $0.start < end }.count
            for a in snap.avr {
                let aEnd = a.end ?? (a.id == snap.currentAVRID ? now : a.start)
                let overlap = min(aEnd, end).timeIntervalSince(max(a.start, start))
                if a.start >= start && a.start < end { s.avrCount += 1 }
                if overlap > 0 { s.avrSeconds += overlap }
            }
            if let d = stats[key] {
                s.inputMin = d.inputMin
                s.inputMax = d.inputMax
                s.inputAverage = d.inputAverage
            }
            result.append(s)
        }
        return result
    }
}
