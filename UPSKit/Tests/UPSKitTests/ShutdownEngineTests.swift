import Foundation
import Testing
@testable import UPSKit

struct ShutdownEngineTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func online() -> UPSStatus { UPSStatus(batteryVoltage: 27.3) }

    func onBattery(percent: Int = 100, low: Bool = false) -> UPSStatus {
        UPSStatus(batteryVoltage: 25.5, batteryPercent: percent, onBattery: true, batteryLow: low)
    }

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test func singleOnBatteryReadingIsNotAnOutage() {
        var e = ShutdownEngine()
        #expect(e.ingest(online(), at: at(0)).isEmpty)
        #expect(e.ingest(onBattery(), at: at(5)).isEmpty)
        #expect(e.ingest(online(), at: at(10)).isEmpty)
        #expect(e.phase == .online)
    }

    @Test func twoReadingsConfirmOutageFromFirstReading() {
        var e = ShutdownEngine()
        _ = e.ingest(online(), at: at(0))
        _ = e.ingest(onBattery(), at: at(5))
        #expect(e.ingest(onBattery(), at: at(10)) == [.outageConfirmed(since: at(5))])
        #expect(e.phase == .onBattery(since: at(5)))
    }

    @Test func powerRestoredReportsDuration() {
        var e = ShutdownEngine()
        _ = e.ingest(onBattery(), at: at(0))
        _ = e.ingest(onBattery(), at: at(5))
        #expect(e.ingest(online(), at: at(65)) == [.powerRestored(outageDuration: 65, shutdownCancelled: false)])
        #expect(e.phase == .online)
    }

    @Test func upsLowBatteryConfirmsImmediatelyAndWarns() {
        var e = ShutdownEngine()
        let events = e.ingest(onBattery(low: true), at: at(0))
        #expect(events == [
            .outageConfirmed(since: at(0)),
            .warningStarted(reason: .upsBatteryLow, deadline: at(60)),
        ])
    }

    @Test func percentThresholdTriggersWarningThenShutdown() {
        var e = ShutdownEngine()
        _ = e.ingest(onBattery(), at: at(0))
        _ = e.ingest(onBattery(), at: at(5))
        #expect(e.ingest(onBattery(percent: 29), at: at(10)) == [
            .warningStarted(reason: .batteryBelow(percent: 29, threshold: 30), deadline: at(70)),
        ])
        #expect(e.tick(at: at(69)).isEmpty)
        #expect(e.tick(at: at(70)) == [.shutdownNow(reason: .batteryBelow(percent: 29, threshold: 30))])
        #expect(e.ingest(onBattery(percent: 28), at: at(75)).isEmpty)   // no repite
    }

    @Test func timeOnBatteryTriggersWarning() {
        var e = ShutdownEngine()
        _ = e.ingest(onBattery(), at: at(0))
        _ = e.ingest(onBattery(), at: at(5))
        #expect(e.ingest(onBattery(), at: at(599)).isEmpty)
        #expect(e.ingest(onBattery(), at: at(600)) == [.warningStarted(reason: .timeOnBattery(minutes: 10), deadline: at(660))])
    }

    @Test func disabledThresholdsNeverWarn() {
        var policy = ShutdownPolicy()
        policy.onUPSLowBattery = false
        policy.minBatteryPercent = 0
        policy.maxMinutesOnBattery = 0
        var e = ShutdownEngine(policy: policy)
        _ = e.ingest(onBattery(), at: at(0))
        _ = e.ingest(onBattery(), at: at(5))
        #expect(e.ingest(onBattery(percent: 0, low: true), at: at(3600)).isEmpty)
    }

    @Test func powerReturnDuringWarningCancelsShutdown() {
        var e = ShutdownEngine()
        _ = e.ingest(onBattery(low: true), at: at(0))
        #expect(e.ingest(online(), at: at(20)) == [.powerRestored(outageDuration: 20, shutdownCancelled: true)])
        #expect(e.tick(at: at(100)).isEmpty)
    }

    @Test func postponeSnoozesThenWarnsAgain() {
        var e = ShutdownEngine()
        _ = e.ingest(onBattery(), at: at(0))
        _ = e.ingest(onBattery(percent: 20), at: at(5))
        #expect(e.phase.isWarning)
        #expect(e.postpone(minutes: 5, at: at(10)) == [.postponed(until: at(310))])
        #expect(e.ingest(onBattery(percent: 18), at: at(15)).isEmpty)
        #expect(e.ingest(onBattery(percent: 15), at: at(310)).count == 1)
        #expect(e.phase.isWarning)
    }

    @Test func cannotPostponeUPSLowBattery() {
        var e = ShutdownEngine()
        _ = e.ingest(onBattery(low: true), at: at(0))
        #expect(e.postpone(minutes: 5, at: at(10)).isEmpty)
        #expect(e.phase.isWarning)
    }

    @Test func upsLowBatteryOverridesSnooze() {
        var e = ShutdownEngine()
        _ = e.ingest(onBattery(), at: at(0))
        _ = e.ingest(onBattery(percent: 20), at: at(5))
        _ = e.postpone(minutes: 5, at: at(10))
        #expect(e.ingest(onBattery(percent: 10, low: true), at: at(20)) == [
            .warningStarted(reason: .upsBatteryLow, deadline: at(80)),
        ])
    }

    @Test func communicationLossNeedsTwoFailuresAndNeverShutsDown() {
        var e = ShutdownEngine()
        _ = e.ingest(online(), at: at(0))
        #expect(e.ingestFailure(at: at(5)).isEmpty)
        #expect(e.ingestFailure(at: at(10)) == [.communicationLost])
        #expect(e.ingestFailure(at: at(15)).isEmpty)   // no repite
        #expect(e.ingest(online(), at: at(20)) == [.communicationRestored])
    }

    @Test func communicationLossAbortsWarning() {
        var e = ShutdownEngine()
        _ = e.ingest(onBattery(low: true), at: at(0))
        _ = e.ingestFailure(at: at(5))
        #expect(e.ingestFailure(at: at(10)) == [.communicationLost, .warningAborted])
        #expect(e.phase == .onBattery(since: at(0)))
        #expect(e.tick(at: at(120)).isEmpty)
    }

    @Test func userCanShutDownImmediately() {
        var e = ShutdownEngine()
        _ = e.ingest(onBattery(), at: at(0))
        _ = e.ingest(onBattery(percent: 20), at: at(5))
        #expect(e.shutdownImmediately(at: at(8)) == [.shutdownNow(reason: .batteryBelow(percent: 20, threshold: 30))])
    }

    @Test func failedShutdownWarnsAgainOnNextReading() {
        var e = ShutdownEngine()
        _ = e.ingest(onBattery(low: true), at: at(0))
        _ = e.tick(at: at(60))
        e.shutdownDidNotComplete()
        #expect(e.ingest(onBattery(low: true), at: at(180)) == [
            .warningStarted(reason: .upsBatteryLow, deadline: at(240)),
        ])
    }

    @Test func zeroWarningShutsDownAtOnce() {
        var policy = ShutdownPolicy()
        policy.warningSeconds = 0
        var e = ShutdownEngine(policy: policy)
        #expect(e.ingest(onBattery(low: true), at: at(0)) == [
            .outageConfirmed(since: at(0)),
            .warningStarted(reason: .upsBatteryLow, deadline: at(0)),
            .shutdownNow(reason: .upsBatteryLow),
        ])
    }
}
