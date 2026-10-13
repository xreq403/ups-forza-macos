import Foundation
import Testing
@testable import UPSKit

struct LogImporterTests {
    /// Líneas reales de los registros del 2026-10-12/13 (recortadas).
    static let log = """
    2026-10-12 22:49:44 Inicio de UPS Forza
    2026-10-12 22:50:00 LECTURA ent=237.2V sal=237.2V carga=5% bat=27.29V (100%) frec=50.0Hz bits=00001001
    2026-10-12 22:50:07 CORTE de luz confirmado
    2026-10-12 22:50:08 LECTURA ent=8.5V sal=224.4V carga=6% bat=25.29V (100%) frec=50.0Hz bits=10001000
    2026-10-12 22:50:13 LECTURA ent=8.5V sal=224.4V carga=7% bat=25.18V (99%) frec=50.0Hz bits=10001000
    2026-10-12 22:50:18 VOLVIÓ la luz tras 16 s
    2026-10-13 07:06:06 LECTURA ent=239.3V sal=239.3V carga=4% bat=27.18V (100%) frec=50.0Hz bits=00001000
    2026-10-13 07:07:06 LECTURA ent=239.3V sal=201.8V carga=5% bat=27.18V (100%) frec=50.0Hz bits=00101000
    2026-10-13 07:08:06 LECTURA ent=239.3V sal=201.8V carga=4% bat=27.18V (100%) frec=50.0Hz bits=00101000
    2026-10-13 07:09:06 LECTURA ent=237.2V sal=237.2V carga=4% bat=27.18V (100%) frec=50.0Hz bits=00001000
    2026-10-13 07:26:44 CORTE de luz confirmado
    2026-10-13 07:27:00 LECTURA ent=8.5V sal=224.4V carga=6% bat=25.41V (100%) frec=50.0Hz bits=10001000
    2026-10-13 07:28:39 AVISO de apagado en 60 s: 2 min seguidos sin luz
    2026-10-13 07:29:39 APAGANDO la Mac: 2 min seguidos sin luz
    2026-10-13 07:31:45 Inicio de UPS Forza
    """

    func parsed() -> (outages: [OutageRecord], avr: [AVRRecord], days: [DayStats]) {
        var o: [OutageRecord] = [], a: [AVRRecord] = [], d: [DayStats] = []
        for line in LogImporter.lines(fromLogs: [Self.log]) {
            switch line {
            case .outage(let r): o.append(r)
            case .avr(let r): a.append(r)
            case .day(let s): d.append(s)
            case .batteryTest, .microOutage, .calibration, .recharge: break
            }
        }
        return (o.sorted { $0.start < $1.start }, a, d.sorted { $0.day < $1.day })
    }

    @Test func outages() throws {
        let o = parsed().outages
        #expect(o.count == 2)
        let first = try #require(o.first)
        #expect(first.end!.timeIntervalSince(first.start) == 16)   // usa la duración de "VOLVIÓ"
        #expect(first.minBatteryVoltage == 25.18)
        #expect(first.minBatteryPercent == 99)
        #expect(first.maxLoadPercent == 7)
        #expect(first.shutdownReason == nil)
        #expect(first.imported)
        #expect(o[1].shutdownReason == .timeOnBattery(minutes: 2))
        #expect(o[1].end != nil)
    }

    @Test func avrBuck() throws {
        let a = try #require(parsed().avr.first)
        #expect(parsed().avr.count == 1)
        #expect(a.mode == .buck)
        #expect(a.end!.timeIntervalSince(a.start) == 120)       // 07:07:06 → 07:09:06
        #expect(a.inputMax == 239.3)
        #expect(a.outputMin == 201.8)
    }

    @Test func dayStatsIgnoreBatteryReadings() {
        let d = parsed().days
        #expect(d.map(\.day) == ["2026-10-12", "2026-10-13"])
        #expect(d[0].inputMin == 237.2)                            // sin los 8,5 V del corte
        #expect(d[1].inputMax == 239.3)
    }

    @Test func onlineReadingClosesOutageWithoutRestoreLine() throws {
        let text = """
        2026-10-12 10:00:00 CORTE de luz confirmado
        2026-10-12 10:00:05 LECTURA ent=8.5V sal=224.4V carga=6% bat=25.29V (100%) frec=50.0Hz bits=10001000
        2026-10-12 10:05:00 Inicio de UPS Forza
        2026-10-12 10:05:01 LECTURA ent=237.2V sal=237.2V carga=5% bat=26.10V (100%) frec=50.0Hz bits=00001000
        """
        let outages = LogImporter.lines(fromLogs: [text]).compactMap { line -> OutageRecord? in
            if case .outage(let r) = line { r } else { nil }
        }
        let o = try #require(outages.first)
        #expect(outages.count == 1)
        #expect(o.end!.timeIntervalSince(o.start) == 301)
    }

    @Test func durations() {
        #expect(LogImporter.duration("16 s") == 16)
        #expect(LogImporter.duration("1 min 5 s") == 65)
        #expect(LogImporter.duration("1 h 05 min") == 3900)
        #expect(LogImporter.duration("pronto") == nil)
    }

    @Test(arguments: [
        ShutdownReason.upsBatteryLow,
        .timeOnBattery(minutes: 10),
        .batteryBelow(percent: 8, threshold: 10),
    ])
    func reasonRoundTrip(reason: ShutdownReason) {
        #expect(LogImporter.reason(reason.description) == reason)
    }
}

struct HistoryStoreTests {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "history-\(UUID().uuidString).jsonl")
    }

    let t0 = Date(timeIntervalSinceNow: -3600)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    @Test func recordsOutageAndSurvivesReload() {
        let url = tempURL()
        let store = HistoryStore(url: url)
        #expect(store.isNew)
        store.outageStarted(at: at(0))
        store.ingest(UPSStatus(batteryVoltage: 25.2, batteryPercent: 99, onBattery: true), at: at(5))
        store.ingest(UPSStatus(loadPercent: 7, batteryVoltage: 24.9, batteryPercent: 90, onBattery: true), at: at(10))
        store.outageEnded(at: at(60))

        let reloaded = HistoryStore(url: url)
        #expect(!reloaded.isNew)
        let o = reloaded.snapshot(since: at(-60)).outages
        #expect(o.count == 1)
        #expect(o[0].end == at(60))
        #expect(o[0].maxLoadPercent == 7)
        #expect(o[0].minBatteryPercent == 90)
    }

    @Test func shutdownClosesOutageImmediately() {
        let url = tempURL()
        let store = HistoryStore(url: url)
        store.outageStarted(at: at(0))
        store.shutdown(reason: .upsBatteryLow, at: at(30))
        // Simula que el proceso muere sin nada más: lo escrito tiene que alcanzar.
        let o = HistoryStore(url: url).snapshot(since: at(-60)).outages
        #expect(o.first?.shutdownReason == .upsBatteryLow)
        #expect(o.first?.end == at(30))
    }

    @Test func avrEpisodeOpensAndCloses() {
        let store = HistoryStore(url: tempURL())
        store.ingest(UPSStatus(inputVoltage: 239.3, outputVoltage: 237.2), at: at(0))
        store.ingest(UPSStatus(inputVoltage: 239.3, outputVoltage: 201.8, avrActive: true), at: at(5))
        store.ingest(UPSStatus(inputVoltage: 240.1, outputVoltage: 202.0, avrActive: true), at: at(10))
        #expect(store.snapshot(since: at(-60)).currentAVRID != nil)
        store.ingest(UPSStatus(inputVoltage: 237.2, outputVoltage: 237.2), at: at(15))
        let snap = store.snapshot(since: at(-60))
        #expect(snap.currentAVRID == nil)
        #expect(snap.avr.count == 1)
        #expect(snap.avr[0].mode == .buck)
        #expect(snap.avr[0].inputMax == 240.1)
        #expect(snap.avr[0].end == at(15))
    }

    @Test func dailySummaryClipsToDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Asuncion")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12))!
        let midnight = cal.startOfDay(for: now)
        // Corte de 23:50 a 00:20: 10 min el día anterior, 20 min hoy.
        var outage = OutageRecord(start: midnight.addingTimeInterval(-600))
        outage.end = midnight.addingTimeInterval(1200)
        let snap = HistorySnapshot(outages: [outage])
        let days = HistorySummary.daily(snap, days: 2, now: now, calendar: cal)
        #expect(days[0].outageSeconds == 1200)
        #expect(days[0].outages == 0)          // empezó ayer
        #expect(days[1].outageSeconds == 600)
        #expect(days[1].outages == 1)
    }
}

struct HistoryClearTests {
    @Test func clearEmptiesAndDoesNotReimport() async {
        let dir = FileManager.default.temporaryDirectory.appending(path: "clear-\(UUID().uuidString)")
        let logURL = dir.appending(path: "ups-forza.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? LogImporterTests.log.write(to: logURL, atomically: true, encoding: .utf8)
        let historyURL = dir.appending(path: "history.jsonl")

        let core = MonitorCore(device: FakeUPS(), settings: MonitorSettings(), log: EventLog(url: logURL),
                               forced: .unavailable(retryAfter: 120), historyURL: historyURL, importLogs: [logURL])
        await core.start()
        await core.stop()
        #expect(await !core.history(days: 3650).outages.isEmpty)   // importó del registro

        await core.clearHistory(includeLogs: true)
        #expect(await core.history(days: 3650).outages.isEmpty)

        // Al reiniciar no vuelve a importar: el archivo de historial existe (vacío).
        let again = MonitorCore(device: FakeUPS(), settings: MonitorSettings(), log: EventLog(url: logURL),
                                forced: .unavailable(retryAfter: 120), historyURL: historyURL, importLogs: [logURL])
        await again.start()
        await again.stop()
        #expect(await again.history(days: 3650).outages.isEmpty)
    }
}

struct HistoryMergeTests {
    @Test func mergeAddsWithoutDuplicates() {
        let tmp = FileManager.default.temporaryDirectory
        let local = HistoryStore(url: tmp.appending(path: "local-\(UUID().uuidString).jsonl"))
        let t0 = Date(timeIntervalSinceNow: -600)
        local.outageStarted(at: t0)
        local.outageEnded(at: t0.addingTimeInterval(30))
        local.record(batteryTest: BatteryTestRecord(start: t0, trigger: .manual, outcome: .passed,
                                                    voltageBefore: 27.29, voltageMin: 26.0, health: .reference))
        let data = try! Data(contentsOf: local.url)

        let daemon = HistoryStore(url: tmp.appending(path: "daemon-\(UUID().uuidString).jsonl"))
        daemon.merge(jsonl: data)
        daemon.merge(jsonl: data)   // dos veces: sin duplicados
        let snap = daemon.snapshot(since: t0.addingTimeInterval(-60))
        #expect(snap.outages.count == 1)
        #expect(snap.batteryTests.count == 1)
        #expect(daemon.referenceBatteryTest?.voltageMin == 26.0)
    }
}

struct MicroOutageTests {
    let t0 = Date(timeIntervalSinceNow: -600)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    func store() -> HistoryStore {
        HistoryStore(url: FileManager.default.temporaryDirectory.appending(path: "micro-\(UUID().uuidString).jsonl"))
    }
    let online = UPSStatus(inputVoltage: 235, outputVoltage: 235)
    let battery = UPSStatus(inputVoltage: 8.5, outputVoltage: 224, onBattery: true)

    @Test func singleBatteryReadingIsMicroOutage() {
        let h = store()
        h.ingest(online, at: at(0))
        h.ingest(battery, at: at(5))
        h.ingest(online, at: at(10))
        let m = h.snapshot(since: at(-60)).microOutages
        #expect(m.count == 1)
        #expect(m.first?.start == at(5))
        #expect(m.first?.end == at(10))
        #expect(m.first?.readings == 1)
    }

    @Test func confirmedOutageIsNotMicro() {
        let h = store()
        h.ingest(battery, at: at(5))
        h.outageStarted(at: at(5))          // el engine lo confirmó
        h.ingest(battery, at: at(10))
        h.outageEnded(at: at(20))
        h.ingest(online, at: at(20))
        let snap = h.snapshot(since: at(-60))
        #expect(snap.microOutages.isEmpty)
        #expect(snap.outages.count == 1)
    }

    @Test func countedInDailySummary() {
        let snap = HistorySnapshot(microOutages: [MicroOutageRecord(start: .now.addingTimeInterval(-60), end: .now)])
        #expect(HistorySummary.daily(snap, days: 1).first?.microOutages == 1)
    }
}

struct SeriesTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // múltiplo de 60 s
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    let online = UPSStatus(inputVoltage: 235, outputVoltage: 235, loadPercent: 5, batteryVoltage: 27.3)
    let battery = UPSStatus(inputVoltage: 8.5, outputVoltage: 224, loadPercent: 7, batteryVoltage: 25.2, onBattery: true)

    @Test func rawLastHourAndMinuteAggregates() {
        let s = SeriesStore(url: nil)
        for i in 0..<24 { s.add(i == 13 ? battery : online, at: at(Double(i) * 5)) }   // 2 minutos
        #expect(s.series(.hour1, now: at(120)).count == 24)
        let minutes = s.series(.hours6, now: at(120))
        #expect(minutes.count == 2)
        #expect(minutes[0].onBattery == false)
        #expect(minutes[1].onBattery == true)
        #expect(minutes[1].inputMin == 235)          // los 8,5 V del corte no cuentan
        #expect(minutes[1].batteryMin == 25.2)
        #expect(minutes[1].loadMax == 7)
    }

    @Test func dropsReadingsOlderThanAnHour() {
        let s = SeriesStore(url: nil)
        s.add(online, at: at(0))
        s.add(online, at: at(3700))
        #expect(s.series(.hour1, now: at(3700)).count == 1)
    }

    @Test func persistsMinutes() {
        let url = FileManager.default.temporaryDirectory.appending(path: "series-\(UUID().uuidString).json")
        let now = Date.now
        let s = SeriesStore(url: url)
        s.add(online, at: now.addingTimeInterval(-180))
        s.add(online, at: now.addingTimeInterval(-60))   // cierra el minuto anterior
        s.save(at: now)
        #expect(SeriesStore(url: url).series(.hours6, now: now).count >= 1)
    }

    @Test func bucketsOf24Hours() {
        let pts = (0..<10).map { i in SeriesStore.point([online], at: at(Double(i) * 60)) }
        #expect(SeriesStore.bucket(pts, seconds: 300).count == 2)
    }
}
