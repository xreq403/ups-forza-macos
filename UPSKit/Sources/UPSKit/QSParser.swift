import Foundation

public enum ProtocolError: Error, Equatable, CustomStringConvertible {
    case unexpectedResponse([UInt8])
    case unexpectedFieldCount(Int)

    public var description: String {
        switch self {
        case .unexpectedResponse(let raw):
            "Respuesta inesperada: \(raw.hexString)"
        case .unexpectedFieldCount(let n):
            "Número de campos inesperado (\(n))"
        }
    }
}

/// Decodificación de la respuesta a `QS` en formato Voltronic-QS-Hex.
/// Fórmulas tomadas del subdriver de NUT `nutdrv_qx_voltronic-qs-hex.c`.
public enum QSParser {
    /// Secuencias de escape del protocolo: 0x28 seguido de un código.
    static let escapes: [UInt8: UInt8] = [0x00: 0x0D, 0x01: 0x11, 0x02: 0x13, 0x03: 0x0A, 0x04: 0x20]

    /// Separa la respuesta en campos (separados por 0x20) y quita los escapes.
    /// Hay que separar primero y desescapar después: un `28 04` dentro de un
    /// campo es un 0x20 de datos, no un separador.
    public static func tokenize(_ raw: [UInt8]) throws -> [[UInt8]] {
        guard raw.first == UInt8(ascii: "#") else { throw ProtocolError.unexpectedResponse(raw) }
        var body = raw.dropFirst()
        if let cr = body.firstIndex(of: 0x0D) { body = body[..<cr] }

        var tokens: [[UInt8]] = []
        var cur: [UInt8] = []
        var i = body.startIndex
        while i < body.endIndex {
            let b = body[i]
            let next = body.index(after: i)
            if b == 0x20 {
                tokens.append(cur)
                cur = []
            } else if b == 0x28, next < body.endIndex, let unescaped = escapes[body[next]] {
                cur.append(unescaped)
                i = next
            } else {
                cur.append(b)
            }
            i = body.index(after: i)
        }
        tokens.append(cur)
        return tokens
    }

    /// Entero big-endian.
    static func uint(_ bytes: [UInt8]) -> Int {
        bytes.reduce(0) { $0 << 8 | Int($1) }
    }

    public static func parse(_ raw: [UInt8]) throws -> UPSStatus {
        let t = try tokenize(raw).map(uint)
        guard t.count == 10 || t.count == 11 else { throw ProtocolError.unexpectedFieldCount(t.count) }

        let vIn = Double(t[0] * t[1] / 51) / 256
        let vOut = Double(t[2] * t[3] / 51) / 256
        let freq = t[5] != 0 ? min(Double(t[6]) / Double(t[5]), 99.9) : 0
        let vBat = Double(t[7] * t[8]) / 510

        let bits = UInt8(truncatingIfNeeded: t[9])
        func bit(_ n: Int) -> Bool { bits & (1 << n) != 0 }
        let onBattery = bit(7)

        var st = UPSStatus(
            inputVoltage: round(vIn, 1),
            outputVoltage: round(vOut, 1),
            loadPercent: t[4],
            frequency: round(freq, 1),
            batteryVoltage: round(vBat, 2),
            batteryPercent: BatteryEstimator.percent(volts: vBat, onBattery: onBattery),
            charging: !onBattery && vBat < BatteryEstimator.floatVoltage,
            onBattery: onBattery,
            batteryLow: bit(6),
            avrActive: bit(5),
            upsFault: bit(4),
            lineInteractive: bit(3),
            testInProgress: bit(2),
            shutdownActive: bit(1),
            beeperOn: bit(0),
            statusBits: bits
        )

        if t.count == 11 {  // variante 'T': incluye valores nominales
            let r = UInt8(truncatingIfNeeded: t[10])
            st.nominalFrequency = r & 0x80 != 0 ? 60 : 50
            st.nominalBatteryVoltage = [12, 24, 36, 48][Int((r >> 5) & 0b11)]
            let outputs = [110, 120, 220, 230, 240]
            let idx = Int(r & 0b111)
            st.nominalOutputVoltage = idx < outputs.count ? outputs[idx] : nil
        }
        return st
    }

    private static func round(_ v: Double, _ places: Int) -> Double {
        let m = pow(10, Double(places))
        return (v * m).rounded() / m
    }
}

extension Collection<UInt8> {
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
