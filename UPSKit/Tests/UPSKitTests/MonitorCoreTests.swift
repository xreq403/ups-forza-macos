import Foundation
import Testing
@testable import UPSKit

/// UPS simulada: devuelve el estado que el test le asigna y obedece a la alarma.
final class FakeUPS: UPSDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var _status = UPSStatus(batteryVoltage: 27.3)
    private var _fail = false
    private(set) var beeperCommands = 0

    var status: UPSStatus {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var fail: Bool {
        get { lock.withLock { _fail } }
        set { lock.withLock { _fail = newValue } }
    }

    func start(onConnectionChange: @escaping @Sendable (Bool) -> Void) {}
    func stop() {}
    func protocolVariant() async throws -> String { "T" }

    func status() async throws -> UPSStatus {
        if fail { throw TransportError.notConnected }
        return currentStatus()
    }

    /// Test de batería simulado: b2 durante `testReadings` lecturas, con este voltaje.
    var testVoltage = 26.0
    var testFails = false
    var ignoresTest = false
    private var testReadingsLeft = 0
    private(set) var testsStarted = 0

    func startBatteryTest() async throws {
        lock.withLock {
            testsStarted += 1
            if !ignoresTest { testReadingsLeft = 3 }
        }
    }

    /// Lo que devuelve `status()`: durante el test, b2 y el voltaje del test.
    private func currentStatus() -> UPSStatus {
        lock.withLock {
            var s = _status
            if testReadingsLeft > 0 {
                testReadingsLeft -= 1
                s.testInProgress = true
                s.batteryVoltage = testVoltage
                s.batteryLow = testFails
            }
            return s
        }
    }

    func setBeeper(enabled: Bool) async throws -> Bool {
        lock.withLock {
            if _status.beeperOn != enabled {
                _status.beeperOn = enabled
                beeperCommands += 1
            }
            return _status.beeperOn
        }
    }
}

/// Registra las llamadas al apagado forzado.
final class ShutdownRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _reasons: [ShutdownReason] = []
    var reasons: [ShutdownReason] { lock.withLock { _reasons } }
    func record(_ r: ShutdownReason) { lock.withLock { _reasons.append(r) } }
}

struct MonitorCoreTests {
    let log = EventLog(url: FileManager.default.temporaryDirectory.appending(path: "ups-forza-tests.log"))

    /// Batería baja + aviso de 0 s: una sola lectura llega hasta `shutdownNow`.
    func criticalSettings() -> MonitorSettings {
        var s = MonitorSettings()
        s.policy.warningSeconds = 0
        s.beeperEnabled = true
        return s
    }

    func criticalStatus() -> UPSStatus {
        UPSStatus(batteryVoltage: 21.5, batteryPercent: 3, onBattery: true, batteryLow: true)
    }

    func eventKinds(_ snap: MonitorSnapshot) -> [CoreEvent] { snap.events.map(\.event) }

    @Test func forcesImmediatelyWithoutClient() async throws {
        let ups = FakeUPS()
        let rec = ShutdownRecorder()
        let core = MonitorCore(device: ups, settings: criticalSettings(), log: log,
                               forced: .available(grace: 60, hasActiveClient: { false }, execute: rec.record))
        ups.status = criticalStatus()
        await core.pollOnce()
        try await Task.sleep(for: .seconds(0.2))   // sin esperar el margen: solo lo que tarda programar S
        #expect(rec.reasons == [.upsBatteryLow])
        let snap = await core.snapshot(since: 0)
        #expect(eventKinds(snap).contains(.shutdownForced(reason: .upsBatteryLow)))
    }

    @Test func withClientWaitsGraceThenForces() async throws {
        let ups = FakeUPS()
        let rec = ShutdownRecorder()
        let core = MonitorCore(device: ups, settings: criticalSettings(), log: log,
                               forced: .available(grace: 0.3, hasActiveClient: { true }, execute: rec.record))
        ups.status = criticalStatus()
        await core.pollOnce()
        #expect(rec.reasons.isEmpty)                      // primero la app intenta el apagado ordenado
        let snap = await core.snapshot(since: 0)
        #expect(eventKinds(snap).contains(.monitor(.shutdownNow(reason: .upsBatteryLow))))
        try await Task.sleep(for: .seconds(0.6))
        #expect(rec.reasons == [.upsBatteryLow])          // la Mac siguió encendida: se fuerza
    }

    @Test func powerReturnDuringGraceCancelsForce() async throws {
        let ups = FakeUPS()
        let rec = ShutdownRecorder()
        let core = MonitorCore(device: ups, settings: criticalSettings(), log: log,
                               forced: .available(grace: 0.3, hasActiveClient: { true }, execute: rec.record))
        ups.status = criticalStatus()
        await core.pollOnce()
        ups.status = UPSStatus(batteryVoltage: 26.0)     // vuelve la luz
        await core.pollOnce()
        try await Task.sleep(for: .seconds(0.6))
        #expect(rec.reasons.isEmpty)
        #expect(await core.snapshot(since: -1).phase == .online)
    }

    @Test func withoutPrivilegesWarnsAgain() async throws {
        let ups = FakeUPS()
        let core = MonitorCore(device: ups, settings: criticalSettings(), log: log,
                               forced: .unavailable(retryAfter: 0.3))
        ups.status = criticalStatus()
        await core.pollOnce()
        try await Task.sleep(for: .seconds(0.6))
        let snap = await core.snapshot(since: 0)
        #expect(eventKinds(snap).contains(.shutdownIncomplete))
        if case .onBattery = snap.phase {} else { Issue.record("fase esperada onBattery, fue \(snap.phase)") }
    }

    @Test func communicationLossNeverForces() async {
        let ups = FakeUPS()
        let rec = ShutdownRecorder()
        let core = MonitorCore(device: ups, settings: MonitorSettings(), log: log,
                               forced: .available(grace: 0, hasActiveClient: { false }, execute: rec.record))
        ups.status = UPSStatus(batteryVoltage: 27.3)
        await core.pollOnce()
        ups.fail = true
        await core.pollOnce()
        await core.pollOnce()
        let snap = await core.snapshot(since: 0)
        #expect(snap.link == .lost)
        #expect(eventKinds(snap).contains(.monitor(.communicationLost)))
        #expect(rec.reasons.isEmpty)
    }

    @Test func appliesBeeperSetting() async {
        let ups = FakeUPS()
        var settings = MonitorSettings()
        settings.beeperEnabled = false
        let core = MonitorCore(device: ups, settings: settings, log: log,
                               forced: .unavailable(retryAfter: 120))
        ups.status = UPSStatus(batteryVoltage: 27.3, beeperOn: true)
        await core.pollOnce()
        #expect(ups.status.beeperOn == false)
        await core.pollOnce()
        #expect(ups.beeperCommands == 1)                  // no vuelve a alternar
    }

    @Test func snapshotSinceMinusOneSkipsHistory() async {
        let ups = FakeUPS()
        let core = MonitorCore(device: ups, settings: criticalSettings(), log: log,
                               forced: .unavailable(retryAfter: 120))
        ups.status = criticalStatus()
        await core.pollOnce()
        let fresh = await core.snapshot(since: -1)
        #expect(fresh.events.isEmpty)
        #expect(fresh.lastEventID > 0)
        let later = await core.snapshot(since: fresh.lastEventID)
        #expect(later.events.isEmpty)
    }

    @Test func snapshotRoundTripsAsJSON() async throws {
        let ups = FakeUPS()
        let core = MonitorCore(device: ups, settings: criticalSettings(), log: log,
                               forced: .unavailable(retryAfter: 120))
        ups.status = criticalStatus()
        await core.pollOnce()
        let snap = await core.snapshot(since: 0)
        let data = try DaemonIdentity.jsonEncoder.encode(snap)
        let back = try DaemonIdentity.jsonDecoder.decode(MonitorSnapshot.self, from: data)
        #expect(back.phase == snap.phase)
        #expect(back.events == snap.events)
        #expect(back.status == snap.status)
    }
}

struct MonitorCoreBeeperTests {
    let log = EventLog(url: FileManager.default.temporaryDirectory.appending(path: "ups-forza-tests.log"))

    @Test func doesNotTouchBeeperUntilSettingsArrive() async {
        let ups = FakeUPS()
        let core = MonitorCore(device: ups, settings: MonitorSettings(), log: log,
                               forced: .unavailable(retryAfter: 120), enforceBeeper: false)
        ups.status = UPSStatus(batteryVoltage: 27.3, beeperOn: false)   // silenciada por el usuario
        await core.pollOnce()
        #expect(ups.beeperCommands == 0)                                  // el default (activada) no se aplica
        var user = MonitorSettings()
        user.beeperEnabled = false
        await core.update(settings: user)
        await core.pollOnce()
        #expect(ups.status.beeperOn == false)
        #expect(ups.beeperCommands == 0)
    }
}


struct SettingsCompatibilityTests {
    @Test func oldSettingsJSONKeepsValues() throws {
        // settings.json de una versión anterior (sin campos opcionales).
        let old = #"{"pollInterval":5,"policy":{"minBatteryPercent":10,"maxMinutesOnBattery":0,"debounceReadings":2,"warningSeconds":60,"onUPSLowBattery":true},"beeperEnabled":false}"#
        let s = try JSONDecoder().decode(MonitorSettings.self, from: Data(old.utf8))
        #expect(s.beeperEnabled == false)
        #expect(s.policy.minBatteryPercent == 10)
    }

    @Test func ignoresUnknownKeys() throws {
        // settings.json escrito por la versión que tenía el apagado de la salida (S<n>).
        let withRemoved = #"{"pollInterval":5,"policy":{"minBatteryPercent":10},"beeperEnabled":false,"upsOutputOffAfterShutdown":false,"upsOutputOffDelayMinutes":5}"#
        let s = try JSONDecoder().decode(MonitorSettings.self, from: Data(withRemoved.utf8))
        #expect(s.beeperEnabled == false)
        #expect(s.policy.minBatteryPercent == 10)
        #expect(s.policy.warningSeconds == ShutdownPolicy().warningSeconds)
    }
}

struct PowerManagementTests {
    @Test func parsesAutoRestartNotAtConnect() {
        let out = """
        System-wide power settings:
        Currently in use:
         autorestartatconnect 1
         autorestart          0
         powernap             1
        """
        #expect(PowerManagement.parseAutoRestart(out) == false)
        #expect(PowerManagement.parseAutoRestart(" autorestart 1") == true)
        #expect(PowerManagement.parseAutoRestart(" autorestartatconnect 1") == nil)
    }
}


struct BatteryTestTests {
    func core(_ ups: FakeUPS, history: URL? = nil) -> MonitorCore {
        MonitorCore(device: ups, settings: MonitorSettings(),
                    log: EventLog(url: FileManager.default.temporaryDirectory.appending(path: "ups-forza-tests.log")),
                    forced: .unavailable(retryAfter: 120), historyURL: history)
    }

    func online() -> UPSStatus { UPSStatus(loadPercent: 5, batteryVoltage: 27.29) }

    func tempHistory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "bt-\(UUID().uuidString).jsonl")
    }

    @Test func firstPassedTestIsReference() async throws {
        let ups = FakeUPS()
        ups.status = online()
        let c = core(ups, history: tempHistory())
        await c.pollOnce()
        await c.pollOnce()
        let r = try #require(await c.runBatteryTest(trigger: .manual).record)
        #expect(r.outcome == .passed)
        #expect(r.voltageMin == 26.0)
        #expect(r.voltageBefore == 27.29)
        #expect(r.health == .reference)
        #expect(ups.testsStarted == 1)
    }

    @Test func detectsDegradationAgainstReference() async throws {
        let ups = FakeUPS()
        ups.status = online()
        let c = core(ups, history: tempHistory())
        await c.pollOnce()
        await c.pollOnce()
        _ = await c.runBatteryTest(trigger: .manual)          // referencia: 26,0 V
        ups.testVoltage = 25.4                                 // 0,6 V peor
        let r = try #require(await c.runBatteryTest(trigger: .manual).record)
        #expect(r.health == .degrading)
        #expect(r.referenceVoltage == 26.0)
    }

    @Test func lowBatteryDuringTestFails() async throws {
        let ups = FakeUPS()
        ups.status = online()
        ups.testFails = true
        let c = core(ups)
        await c.pollOnce()
        await c.pollOnce()
        let r = try #require(await c.runBatteryTest(trigger: .manual).record)
        #expect(r.outcome == .failed)
        #expect(r.health == .bad)
    }

    @Test func ignoredTestIsNotStarted() async throws {
        let ups = FakeUPS()
        ups.status = online()
        ups.ignoresTest = true
        let c = core(ups)
        await c.pollOnce()
        await c.pollOnce()
        let r = try #require(await c.runBatteryTest(trigger: .manual).record)
        #expect(r.outcome == .notStarted)
    }

    @Test func refusedOnBattery() async {
        let ups = FakeUPS()
        ups.status = UPSStatus(batteryVoltage: 25.0, onBattery: true)
        let c = core(ups)
        await c.pollOnce()
        let resp = await c.runBatteryTest(trigger: .manual)
        #expect(resp.record == nil)
        #expect(resp.error != nil)
        #expect(ups.testsStarted == 0)
    }

    @Test func testIsRecordedInHistoryAndEvents() async throws {
        let ups = FakeUPS()
        ups.status = online()
        let url = tempHistory()
        let c = core(ups, history: url)
        await c.pollOnce()
        await c.pollOnce()
        _ = await c.runBatteryTest(trigger: .manual)
        #expect(await c.history(days: 1).batteryTests.count == 1)
        let snap = await c.snapshot(since: 0)
        #expect(snap.lastBatteryTest?.outcome == .passed)
        #expect(snap.events.contains { if case .batteryTestFinished = $0.event { true } else { false } })
    }
}
