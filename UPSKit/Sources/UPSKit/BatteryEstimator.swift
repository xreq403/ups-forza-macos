import Foundation

/// Estimación del % de batería para el banco de plomo-ácido de 24 V (2 × 12 V).
///
/// La curva vale para carga ligera (< 20 %). Con más carga el voltaje cae más,
/// así que el % es solo orientativo: para apagar, confiar en el bit de
/// "batería baja" de la UPS y/o en el tiempo transcurrido sin luz.
public enum BatteryEstimator {
    /// Pares (voltios, %), de mayor a menor voltaje.
    public static let curve: [(volts: Double, percent: Double)] = [
        (25.2, 100),
        (24.9, 90),
        (24.6, 75),
        (24.3, 60),
        (24.0, 45),
        (23.6, 30),
        (23.0, 15),
        (22.0, 5),
        (21.0, 0),
    ]

    /// Por encima de esto, con luz, el cargador está en flotación (batería llena).
    public static let floatVoltage = 26.8

    /// Con luz el voltaje lo impone el cargador y no refleja la carga real,
    /// así que se informa 100 %. En batería se interpola sobre `curve`.
    public static func percent(volts: Double, onBattery: Bool) -> Int {
        guard onBattery, volts < curve[0].volts else { return 100 }
        for (hi, lo) in zip(curve, curve.dropFirst()) where volts >= lo.volts {
            let p = lo.percent + (volts - lo.volts) / (hi.volts - lo.volts) * (hi.percent - lo.percent)
            return Int(p.rounded())
        }
        return 0
    }

    /// Inversa de la curva: voltaje que corresponde a `percent` en batería.
    public static func volts(forPercent percent: Double) -> Double {
        if percent >= curve[0].percent { return curve[0].volts }
        for (hi, lo) in zip(curve, curve.dropFirst()) where percent >= lo.percent {
            return lo.volts + (percent - lo.percent) / (hi.percent - lo.percent) * (hi.volts - lo.volts)
        }
        return curve.last!.volts
    }
}
