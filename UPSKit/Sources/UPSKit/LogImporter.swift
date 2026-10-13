import Foundation

/// Reconstruye el historial a partir de los registros de texto (`ups-forza.log`),
/// para no perder lo ocurrido antes de que existiera el historial. Los datos son
/// aproximados: con luz hay una lectura por minuto.
public enum LogImporter {
    /// Si entre dos lecturas pasa más que esto, el monitor no estaba corriendo:
    /// un AVR abierto se cierra en la última lectura.
    static let maxGap: TimeInterval = 5 * 60

    public static func lines(fromLogs texts: [String]) -> [HistoryLine] {
        let entries = texts.flatMap(parse).sorted { $0.date < $1.date }
        var outages: [OutageRecord] = []
        var avr: [AVRRecord] = []
        var days: [String: DayStats] = [:]
        var openOutage: OutageRecord?
        var openAVR: AVRRecord?
        var lastReading: Date?

        func closeAVR(at date: Date) {
            guard var r = openAVR else { return }
            r.end = date
            avr.append(r)
            openAVR = nil
        }

        for e in entries {
            switch e.kind {
            case .reading(let s):
                if let last = lastReading, e.date.timeIntervalSince(last) > maxGap { closeAVR(at: last) }
                lastReading = e.date
                if s.onBattery {
                    openOutage?.include(s)
                    closeAVR(at: e.date)
                } else {
                    // Lectura con luz y un corte abierto: el "VOLVIÓ" no quedó registrado
                    // (p. ej. la app se cerró). El corte terminó, como tarde, aquí.
                    if var r = openOutage {
                        r.end = e.date
                        outages.append(r)
                        openOutage = nil
                    }
                    if s.inputVoltage > 50 {
                        let key = HistoryStore.dayKey(e.date)
                        if days[key] == nil { days[key] = DayStats(day: key, input: s.inputVoltage) } else { days[key]?.include(s.inputVoltage) }
                    }
                    if s.avrActive {
                        if openAVR == nil { openAVR = AVRRecord(start: e.date, status: s, imported: true) } else { openAVR?.include(s) }
                    } else {
                        closeAVR(at: e.date)
                    }
                }

            case .outageConfirmed:
                // Repetido si la app se reinició durante el mismo corte.
                if openOutage == nil { openOutage = OutageRecord(start: e.date, imported: true) }

            case .powerRestored(let duration):
                var r = openOutage ?? OutageRecord(start: e.date, imported: true)
                if let duration { r.start = min(r.start, e.date.addingTimeInterval(-duration)) }
                r.end = e.date
                outages.append(r)
                openOutage = nil

            case .shutdown(let reason):
                guard var r = openOutage else { break }
                r.shutdownReason = reason
                r.end = e.date
                outages.append(r)
                openOutage = nil
            }
        }
        if let last = lastReading { closeAVR(at: last) }
        if let r = openOutage { outages.append(r) }   // quedó sin cerrar

        return outages.map(HistoryLine.outage) + avr.map(HistoryLine.avr) + days.values.map(HistoryLine.day)
    }

    // MARK: - Parseo

    enum Kind {
        case reading(UPSStatus)
        case outageConfirmed
        case powerRestored(TimeInterval?)
        case shutdown(ShutdownReason)
    }

    struct Entry {
        let date: Date
        let kind: Kind
    }

    static func parse(_ text: String) -> [Entry] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var result: [Entry] = []
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            guard line.count > 20, let date = f.date(from: String(line.prefix(19))) else { continue }
            let msg = String(line.dropFirst(20))
            if msg.hasPrefix("LECTURA "), let s = reading(msg) {
                result.append(Entry(date: date, kind: .reading(s)))
            } else if msg.hasPrefix("CORTE de luz confirmado") {
                result.append(Entry(date: date, kind: .outageConfirmed))
            } else if msg.hasPrefix("VOLVIÓ la luz tras ") {
                let rest = msg.dropFirst("VOLVIÓ la luz tras ".count).split(separator: "(").first.map(String.init) ?? ""
                result.append(Entry(date: date, kind: .powerRestored(duration(rest))))
            } else if msg.hasPrefix("APAGANDO la Mac: ") {
                result.append(Entry(date: date, kind: .shutdown(reason(String(msg.dropFirst("APAGANDO la Mac: ".count))))))
            }
        }
        return result
    }

    /// `LECTURA ent=239.3V sal=201.8V carga=5% bat=27.18V (100%) frec=50.0Hz bits=00101000`
    static func reading(_ msg: String) -> UPSStatus? {
        var fields: [String: String] = [:]
        for part in msg.split(separator: " ") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        func number(_ key: String, _ unit: String) -> Double? {
            fields[key].flatMap { Double($0.replacingOccurrences(of: unit, with: "")) }
        }
        guard let input = number("ent", "V"), let output = number("sal", "V"),
              let battery = number("bat", "V"), let bitsText = fields["bits"],
              let bits = UInt8(bitsText, radix: 2) else { return nil }
        let percent = msg.firstMatch(#"\((\d+)%\)"#).flatMap(Int.init) ?? 100
        return UPSStatus(
            inputVoltage: input,
            outputVoltage: output,
            loadPercent: Int(number("carga", "%") ?? 0),
            frequency: number("frec", "Hz") ?? 0,
            batteryVoltage: battery,
            batteryPercent: percent,
            onBattery: bits & 0x80 != 0,
            batteryLow: bits & 0x40 != 0,
            avrActive: bits & 0x20 != 0,
            upsFault: bits & 0x10 != 0,
            beeperOn: bits & 0x01 != 0,
            statusBits: bits
        )
    }

    /// Inversa de `durationText`: "16 s", "1 min 5 s", "1 h 05 min".
    static func duration(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: " ")
        var total = 0.0
        var i = 0
        var found = false
        while i + 1 < parts.count {
            guard let n = Double(parts[i]) else { i += 1; continue }
            switch parts[i + 1] {
            case "h": total += n * 3600; found = true
            case "min": total += n * 60; found = true
            case "s": total += n; found = true
            default: break
            }
            i += 2
        }
        return found ? total : nil
    }

    /// Inversa de `ShutdownReason.description`.
    static func reason(_ text: String) -> ShutdownReason {
        if text.contains("batería baja") { return .upsBatteryLow }
        if text.contains("min seguidos sin luz"), let m = text.firstMatch(#"(\d+) min"#).flatMap(Int.init) {
            return .timeOnBattery(minutes: m)
        }
        if text.hasPrefix("Batería estimada"),
           let p = text.firstMatch(#"en (\d+) %"#).flatMap(Int.init),
           let t = text.firstMatch(#"mínimo (\d+) %"#).flatMap(Int.init) {
            return .batteryBelow(percent: p, threshold: t)
        }
        return .user
    }
}

private extension String {
    /// Primer grupo de captura de `pattern`.
    func firstMatch(_ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: self) else { return nil }
        return String(self[r])
    }
}
