import Foundation
import Testing
@testable import UPSKit

struct CalibrationTests {
    func core(_ ups: FakeUPS, history: URL? = nil, policy: ShutdownPolicy = ShutdownPolicy()) -> MonitorCore {
        var settings = MonitorSettings()
        settings.policy = policy
        settings.policy.warningSeconds = 60
        return MonitorCore(device: ups, settings: settings,
                           log: EventLog(url: FileManager.default.temporaryDirectory.appending(path: "ups-forza-tests.log")),
                           forced: .unavailable(retryAfter: 120), historyURL: history)
    }

    func tempHistory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cal-\(UUID().uuidString).jsonl")
    }

    func onBattery(_ volts: Double, percent: Int = 50, load: Int = 6) -> UPSStatus {
        UPSStatus(inputVoltage: 8.5, outputVoltage: 224, loadPercent: load, batteryVoltage: volts,
                  batteryPercent: percent, onBattery: true)
    }

    @Test func fitIgnoresInitialDropAndMeasuresSlope() throws {
        // Caída inicial de 27,3 a 25,3 V y luego 0,02 V/min.
        var samples = [CalibrationSample(t: 0, volts: 26.1, load: 6), CalibrationSample(t: 60, volts: 25.4, load: 6)]
        for m in 2...12 { samples.append(CalibrationSample(t: Double(m) * 60, volts: 25.3 - 0.02 * Double(m - 2), load: 6)) }
        let rec = CalibrationRecord(start: .now, end: .now.addingTimeInterval(720), voltageBefore: 27.3,
                                    samples: samples, stopReason: .timeLimit)
        let fit = try #require(rec.fit)
        #expect(abs(fit.slope - 0.02) < 1e-9)
        #expect(abs(fit.intercept - 25.34) < 1e-9)
        let minutes = try #require(rec.projectedMinutes(to: 23.6))
        #expect(abs(minutes - 87) < 1e-6)
        #expect(abs(rec.averageWatts - 72) < 1e-9)
    }

    @Test func tooShortDischargeIsNotUsable() {
        let samples = (0...30).map { CalibrationSample(t: Double($0) * 5, volts: 25.3, load: 6) }
        let rec = CalibrationRecord(start: .now, end: .now, voltageBefore: 27.3, samples: samples, stopReason: .powerRestored)
        #expect(rec.fit == nil)
        #expect(!rec.isUsable)
    }

    @Test func rejectsWhileCharging() async {
        let ups = FakeUPS()
        ups.status = UPSStatus(batteryVoltage: 26.2, charging: true)
        let c = core(ups)
        await c.pollOnce()
        await c.pollOnce()
        #expect(await c.startCalibration(maxMinutes: 30).error != nil)
    }

    @Test func fullFlowSuspendsPolicyAndStoresResult() async throws {
        let ups = FakeUPS()
        ups.status = UPSStatus(loadPercent: 5, batteryVoltage: 27.29)
        let url = tempHistory()
        var policy = ShutdownPolicy()
        policy.minBatteryPercent = 60
        let c = core(ups, history: url, policy: policy)
        await c.pollOnce()
        await c.pollOnce()
        #expect(await c.startCalibration(maxMinutes: 30).error == nil)
        #expect(await c.runBatteryTest(trigger: .manual).error != nil)   // bloqueado durante la calibración

        // Desenchufada: en batería con el % por debajo del umbral, sin aviso de apagado.
        for v in [26.1, 25.4, 25.2, 24.0] {
            ups.status = onBattery(v, percent: 40)
            await c.pollOnce()
        }
        var snap = await c.snapshot(since: 0)
        guard case .discharging = snap.calibration?.phase else { Issue.record("no está descargando"); return }
        #expect(!snap.phase.isWarning)
        #expect(snap.calibration?.samples.count == 4)

        // Llega al mínimo dos lecturas seguidas: termina y vuelve la política (aviso).
        ups.status = onBattery(23.55, percent: 28)
        await c.pollOnce()
        ups.status = onBattery(23.5, percent: 28)
        await c.pollOnce()
        snap = await c.snapshot(since: 0)
        guard case .waitingForPower(_, _, let reason) = snap.calibration?.phase else { Issue.record("no terminó"); return }
        #expect(reason == .targetVoltage)
        #expect(snap.events.contains { $0.event == .calibrationStopped(.targetVoltage) })
        ups.status = onBattery(23.5, percent: 28)
        await c.pollOnce()
        #expect(await c.snapshot(since: 0).phase.isWarning)

        // Vuelve la luz: se guarda el resultado y el corte queda marcado como calibración.
        ups.status = UPSStatus(loadPercent: 5, batteryVoltage: 25.8, charging: true)
        await c.pollOnce()
        snap = await c.snapshot(since: 0)
        #expect(snap.calibration == nil)
        let rec = try #require(snap.lastCalibration)
        #expect(rec.stopReason == .targetVoltage)
        #expect(rec.samples.count == 6)
        #expect(rec.voltageBefore == 27.29)
        #expect(snap.events.contains { if case .calibrationFinished = $0.event { true } else { false } })

        let history = await c.history(days: 1)
        #expect(history.calibrations.count == 1)
        #expect(history.outages.count == 1)
        #expect(history.outages[0].isCalibration)
        #expect(HistorySummary.daily(history, days: 1)[0].outages == 0)

        // Persiste: otro store lee la calibración del archivo.
        let reloaded = HistoryStore(url: url)
        #expect(reloaded.lastCalibration?.id == rec.id)
    }

    @Test func replugBeforeEndSavesMeasured() async throws {
        let ups = FakeUPS()
        ups.status = UPSStatus(loadPercent: 5, batteryVoltage: 27.29)
        let c = core(ups)
        await c.pollOnce()
        await c.pollOnce()
        _ = await c.startCalibration(maxMinutes: 30)
        ups.status = onBattery(25.3)
        await c.pollOnce()
        ups.status = UPSStatus(loadPercent: 5, batteryVoltage: 26.0)
        await c.pollOnce()
        let snap = await c.snapshot(since: 0)
        #expect(snap.calibration == nil)
        #expect(snap.lastCalibration?.stopReason == .powerRestored)
    }

    @Test func cancelBeforeUnplugDiscards() async {
        let ups = FakeUPS()
        ups.status = UPSStatus(loadPercent: 5, batteryVoltage: 27.29)
        let c = core(ups)
        await c.pollOnce()
        _ = await c.startCalibration(maxMinutes: 30)
        await c.cancelCalibration()
        let snap = await c.snapshot(since: 0)
        #expect(snap.calibration == nil)
        #expect(snap.lastCalibration == nil)
    }
}

struct AutonomyTests {
    /// Calibración como la real: 0,026 V/min con ~62 W (5,2 %), recta desde 25,37 V.
    func calibration() -> CalibrationRecord {
        var samples = [CalibrationSample(t: 0, volts: 26.12, load: 5)]
        for m in 2...30 { samples.append(CalibrationSample(t: Double(m) * 60, volts: 25.37 - 0.026 * Double(m), load: 5)) }
        return CalibrationRecord(start: .now, end: .now, voltageBefore: 27.29, samples: samples, stopReason: .timeLimit)
    }

    @Test func inverseCurve() {
        #expect(BatteryEstimator.volts(forPercent: 30) == 23.6)
        #expect(abs(BatteryEstimator.volts(forPercent: 52.5) - 24.15) < 1e-9)
        #expect(BatteryEstimator.volts(forPercent: 100) == 25.2)
    }

    @Test func fullBatteryWithoutThresholds() throws {
        var policy = ShutdownPolicy()
        policy.minBatteryPercent = 0
        policy.maxMinutesOnBattery = 0
        // Al empezar el corte el voltaje está alto (caída inicial): se usa el de batería llena.
        let e = try #require(Autonomy.estimate(volts: 26.1, averageLoad: 5, elapsed: 10,
                                               calibration: calibration(), policy: policy))
        #expect(e.shutdownMinutes == nil)
        #expect(abs(e.minutes - (25.37 - 23.6) / 0.026) < 0.01)
    }

    @Test func doubleLoadHalvesTime() throws {
        var policy = ShutdownPolicy()
        policy.minBatteryPercent = 0
        policy.maxMinutesOnBattery = 0
        let e = try #require(Autonomy.estimate(volts: 24.9, averageLoad: 10, elapsed: 600,
                                               calibration: calibration(), policy: policy))
        #expect(abs(e.batteryMinutes - (24.9 - 23.6) / 0.052) < 0.01)
    }

    @Test func policyTimeLimitIsShorter() throws {
        var policy = ShutdownPolicy()
        policy.minBatteryPercent = 30
        policy.maxMinutesOnBattery = 10
        let e = try #require(Autonomy.estimate(volts: 25.0, averageLoad: 5, elapsed: 240,
                                               calibration: calibration(), policy: policy))
        #expect(e.shutdownMinutes == 6)
        #expect(e.minutes == 6)
        #expect(e.batteryMinutes > 6)
    }
}

struct RechargeTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func core(_ ups: FakeUPS, history: URL? = nil) -> MonitorCore {
        MonitorCore(device: ups, settings: MonitorSettings(),
                    log: EventLog(url: FileManager.default.temporaryDirectory.appending(path: "ups-forza-tests.log")),
                    forced: .unavailable(retryAfter: 120), historyURL: history)
    }

    @Test func estimateGrowsAndCaps() {
        let e = RechargeEstimate(startPercent: 75, since: t0, percentPerHour: 12, measured: false)
        #expect(e.percent(at: t0) == 75)
        #expect(e.percent(at: t0.addingTimeInterval(1800)) == 81)
        #expect(e.percent(at: t0.addingTimeInterval(36_000)) == 99)
        #expect(abs(e.minutesLeft(at: t0) - 125) < 1e-9)
    }

    @Test func rateUsesMeasuredRecharges() {
        #expect(Recharge.rate(from: []) == (12, false))
        let r = RechargeRecord(start: t0, end: t0.addingTimeInterval(2 * 3600), startPercent: 70)   // 15 %/h
        let short = RechargeRecord(start: t0, end: t0.addingTimeInterval(300), startPercent: 96)  // no usable
        let rate = Recharge.rate(from: [r, short])
        #expect(rate.measured)
        #expect(abs(rate.percentPerHour - 15) < 1e-9)
    }

    /// Lectura con luz a `volts`, `minutes` después de t0.
    func online(_ volts: Double) -> UPSStatus {
        UPSStatus(loadPercent: 5, batteryVoltage: volts, batteryPercent: 100, charging: volts < 26.8)
    }

    @Test func trackerFinishesOnStableFloat() throws {
        var tracker = RechargeTracker()
        let rate = (percentPerHour: 12.0, measured: false)
        var s = UPSStatus(batteryVoltage: 24.6, batteryPercent: 74, onBattery: true)
        #expect(tracker.ingest(&s, at: t0, rate: rate) == nil)

        // Vuelve la luz: recargando, % estimado, aunque el voltaje pase 26,8 V.
        s = online(26.5)
        #expect(tracker.ingest(&s, at: t0.addingTimeInterval(5), rate: rate) == nil)
        #expect(s.charging && s.batteryPercent == 74)
        s = online(26.9)
        _ = tracker.ingest(&s, at: t0.addingTimeInterval(3600), rate: rate)
        #expect(s.charging && s.batteryPercent == 86)

        // En 27,0 V pero todavía subiendo: no está llena.
        var t = t0.addingTimeInterval(7200)
        for v in stride(from: 27.0, through: 27.2, by: 0.02) {
            s = online(v)
            #expect(tracker.ingest(&s, at: t, rate: rate) == nil)
            t += 60
        }
        // Estable 10 min: recarga terminada.
        var done: RechargeRecord?
        for _ in 0...10 {
            s = online(27.29)
            done = tracker.ingest(&s, at: t, rate: rate) ?? done
            t += 60
        }
        let r = try #require(done)
        #expect(r.startPercent == 74)
        #expect(r.start == t0.addingTimeInterval(5))
        #expect(tracker.active == nil)
        s = online(27.29)
        _ = tracker.ingest(&s, at: t, rate: rate)
        #expect(!s.charging && s.batteryPercent == 100)
    }

    @Test func microOutageKeepsFull() {
        var tracker = RechargeTracker()
        let rate = (percentPerHour: 12.0, measured: false)
        var s = UPSStatus(batteryVoltage: 25.3, batteryPercent: 100, onBattery: true)
        _ = tracker.ingest(&s, at: t0, rate: rate)
        s = online(26.6)
        _ = tracker.ingest(&s, at: t0.addingTimeInterval(5), rate: rate)
        #expect(s.batteryPercent == 100)
        #expect(tracker.active == nil)
    }

    @Test func coreReportsRechargeAndResumesAfterRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "rc-\(UUID().uuidString).jsonl")
        let ups = FakeUPS()
        let c = core(ups, history: url)
        for _ in 0..<2 {
            ups.status = UPSStatus(loadPercent: 5, batteryVoltage: 24.6, batteryPercent: 74, onBattery: true)
            await c.pollOnce()
        }
        ups.status = online(26.4)
        await c.pollOnce()
        let snap = await c.snapshot(since: 0)
        #expect(snap.status?.batteryPercent == 74)
        #expect(snap.recharge?.startPercent == 74)
        await c.stop()

        // Otro monitor con el mismo historial retoma la recarga del corte.
        let c2 = core(ups, history: url)
        await c2.pollOnce()
        let snap2 = await c2.snapshot(since: 0)
        #expect(snap2.recharge?.startPercent == 74)
        #expect(snap2.status?.charging == true)
    }
}
