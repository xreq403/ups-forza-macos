import Testing
@testable import UPSKit

struct QSParserTests {
    /// Trama real capturada del equipo (spec.md §3.4).
    static let realFrame: [UInt8] = [
        0x23, 0x6d, 0x01, 0x20, 0x6c, 0x20, 0x6d, 0x01, 0x20, 0x6c, 0x20, 0x04, 0x20, 0x60, 0x28, 0x03,
        0x20, 0x12, 0xc0, 0x00, 0x20, 0xe9, 0x20, 0x3c, 0x20, 0x09, 0x20, 0x22, 0x0d,
    ]

    @Test func decodesRealFrame() throws {
        let s = try QSParser.parse(Self.realFrame)
        #expect(s.inputVoltage == 230.8)
        #expect(s.outputVoltage == 230.8)
        #expect(s.loadPercent == 4)
        #expect(s.frequency == 50.0)
        #expect(s.batteryVoltage == 27.41)
        #expect(s.batteryPercent == 100)
        #expect(!s.charging)
        #expect(!s.onBattery)
        #expect(!s.batteryLow)
        #expect(s.lineInteractive)
        #expect(s.beeperOn)
        #expect(!s.upsFault)
        #expect(s.statusBitsString == "00001001")
        #expect(s.nominalFrequency == 50)
        #expect(s.nominalBatteryVoltage == 24)
        #expect(s.nominalOutputVoltage == 220)
    }

    @Test func escapeInsideFieldIsDataNotSeparator() throws {
        // "28 04" es un 0x20 de datos dentro del campo, no un separador.
        let tokens = try QSParser.tokenize([0x23, 0x01, 0x28, 0x04, 0x20, 0x02, 0x0d])
        #expect(tokens == [[0x01, 0x20], [0x02]])
    }

    @Test func allEscapes() throws {
        let tokens = try QSParser.tokenize([0x23, 0x28, 0x00, 0x28, 0x01, 0x28, 0x02, 0x28, 0x03, 0x28, 0x04, 0x0d])
        #expect(tokens == [[0x0D, 0x11, 0x13, 0x0A, 0x20]])
    }

    @Test func tenFieldVariantHasNoNominals() throws {
        let frame = Array(Self.realFrame.prefix(26)) + [0x0d]   // sin el campo 11
        let s = try QSParser.parse(frame)
        #expect(s.batteryVoltage == 27.41)
        #expect(s.nominalOutputVoltage == nil)
    }

    @Test func onBatteryAndLowBatteryBits() throws {
        var frame = Self.realFrame
        frame[25] = 0b1100_1001   // b7 corte, b6 batería baja
        let s = try QSParser.parse(frame)
        #expect(s.onBattery)
        #expect(s.batteryLow)
        #expect(s.batteryPercent == 100)   // 27,41 V en batería sigue siendo ≥ 25,2 V
    }

    @Test func rejectsNonQSReply() {
        #expect(throws: ProtocolError.self) { try QSParser.parse([0x4e, 0x0d]) }   // "N\r"
    }

    @Test func rejectsWrongFieldCount() {
        #expect(throws: ProtocolError.unexpectedFieldCount(3)) {
            try QSParser.parse([0x23, 0x01, 0x20, 0x02, 0x20, 0x03, 0x0d])
        }
    }

    @Test func shutdownCommandFormat() {
        #expect(ForzaUPS.shutdownCommand(minutes: 0.5) == "S.5")
        #expect(ForzaUPS.shutdownCommand(minutes: 2) == "S02")
        #expect(ForzaUPS.shutdownCommand(minutes: 0.1) == "S.2")
        #expect(ForzaUPS.shutdownCommand(minutes: 20) == "S09")
    }
}

struct BatteryEstimatorTests {
    @Test func onlineAlwaysFull() {
        #expect(BatteryEstimator.percent(volts: 24.0, onBattery: false) == 100)
    }

    @Test(arguments: [
        (26.12, 100), (25.2, 100), (24.8, 85), (24.0, 45), (23.6, 30), (22.0, 5), (21.0, 0), (20.0, 0),
    ])
    func curve(volts: Double, expected: Int) {
        #expect(BatteryEstimator.percent(volts: volts, onBattery: true) == expected)
    }
}

struct EstimatedWattsTests {
    @Test(arguments: [(0, 0), (4, 48), (5, 60), (50, 600), (100, 1200)])
    func watts(load: Int, expected: Int) {
        #expect(UPSStatus(loadPercent: load).estimatedWatts == expected)
    }
}
