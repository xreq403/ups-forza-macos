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
        return status
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

    @Test func forcesImmediatelyWithoutClient() async {
        let ups = FakeUPS()
        let rec = ShutdownRecorder()
        let core = MonitorCore(device: ups, settings: criticalSettings(), log: log,
                               forced: .available(grace: 60, hasActiveClient: { false }, execute: rec.record))
        ups.status = criticalStatus()
        await core.pollOnce()
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
