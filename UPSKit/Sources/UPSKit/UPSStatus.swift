import Foundation

/// Estado de la UPS decodificado de la respuesta a `QS`.
public struct UPSStatus: Sendable, Equatable, Codable {
    public var inputVoltage: Double
    public var outputVoltage: Double
    public var loadPercent: Int
    public var frequency: Double
    public var batteryVoltage: Double
    /// Estimación orientativa a partir del voltaje (ver `BatteryEstimator`).
    public var batteryPercent: Int
    /// Con luz, recargando tras un corte.
    public var charging: Bool
    /// Corte de luz: la UPS está entregando energía desde la batería (b7).
    public var onBattery: Bool
    /// La UPS indica batería baja (b6).
    public var batteryLow: Bool
    /// Regulación AVR boost/buck activa (b5).
    public var avrActive: Bool
    /// Falla de la UPS (b4).
    public var upsFault: Bool
    /// Tipo line interactive (b3).
    public var lineInteractive: Bool
    /// Test de batería en curso (b2).
    public var testInProgress: Bool
    /// Apagado programado activo (b1).
    public var shutdownActive: Bool
    /// Alarma sonora activada (b0).
    public var beeperOn: Bool
    /// Byte de estado crudo (campo 10), b7..b0.
    public var statusBits: UInt8
    public var nominalFrequency: Int?
    public var nominalBatteryVoltage: Int?
    public var nominalOutputVoltage: Int?

    public init(
        inputVoltage: Double = 0,
        outputVoltage: Double = 0,
        loadPercent: Int = 0,
        frequency: Double = 0,
        batteryVoltage: Double = 0,
        batteryPercent: Int = 100,
        charging: Bool = false,
        onBattery: Bool = false,
        batteryLow: Bool = false,
        avrActive: Bool = false,
        upsFault: Bool = false,
        lineInteractive: Bool = true,
        testInProgress: Bool = false,
        shutdownActive: Bool = false,
        beeperOn: Bool = true,
        statusBits: UInt8 = 0,
        nominalFrequency: Int? = nil,
        nominalBatteryVoltage: Int? = nil,
        nominalOutputVoltage: Int? = nil
    ) {
        self.inputVoltage = inputVoltage
        self.outputVoltage = outputVoltage
        self.loadPercent = loadPercent
        self.frequency = frequency
        self.batteryVoltage = batteryVoltage
        self.batteryPercent = batteryPercent
        self.charging = charging
        self.onBattery = onBattery
        self.batteryLow = batteryLow
        self.avrActive = avrActive
        self.upsFault = upsFault
        self.lineInteractive = lineInteractive
        self.testInProgress = testInProgress
        self.shutdownActive = shutdownActive
        self.beeperOn = beeperOn
        self.statusBits = statusBits
        self.nominalFrequency = nominalFrequency
        self.nominalBatteryVoltage = nominalBatteryVoltage
        self.nominalOutputVoltage = nominalOutputVoltage
    }

    /// Potencia activa máxima de la NT-2402PRO (2400 VA / 1200 W).
    public static let ratedWatts = 1200

    /// Consumo estimado en watts: `loadPercent` × potencia nominal. Aproximado,
    /// porque la UPS informa el % redondeado y no aclara si es sobre W o VA.
    public var estimatedWatts: Int {
        (loadPercent * Self.ratedWatts + 50) / 100
    }

    /// Bits de estado como texto, b7..b0 (p. ej. `00001001`).
    public var statusBitsString: String {
        let s = String(statusBits, radix: 2)
        return String(repeating: "0", count: 8 - s.count) + s
    }
}
