// upsctl — equivalente en Swift de forza_ups.py, para probar el transporte HID.
//
//   swift run upsctl              estado una vez
//   swift run upsctl --json       salida en JSON
//   swift run upsctl --loop 3     refresca cada 3 s
//   swift run upsctl raw M        envía un comando y muestra la respuesta cruda
//   swift run upsctl beeper off   desactiva la alarma sonora (on para activarla)
//   swift run upsctl battery-test envía T (test rápido de batería) y sigue el estado 30 s

import Foundation
import UPSKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func printStatus(_ s: UPSStatus) {
    let estado = s.onBattery ? "EN BATERÍA (corte de luz)" : "Red eléctrica OK"
    print("Estado          : \(estado)")
    print("Batería         : \(s.batteryPercent)%  (\(String(format: "%.2f", s.batteryVoltage)) V)"
        + (s.charging ? "  (recargando)" : "")
        + (s.batteryLow ? "  ⚠ BATERÍA BAJA" : ""))
    print("Consumo         : \(s.loadPercent)%  (~\(s.estimatedWatts) W)")
    print("Entrada/Salida  : \(s.inputVoltage) V / \(s.outputVoltage) V  @ \(s.frequency) Hz")
    print("AVR activo      : \(s.avrActive ? "sí" : "no")")
    print("Falla UPS       : \(s.upsFault ? "SÍ" : "no")")
    print("Alarma sonora   : \(s.beeperOn ? "activada" : "desactivada")")
    print("Bits de estado  : \(s.statusBitsString)")
    if let v = s.nominalOutputVoltage, let f = s.nominalFrequency, let b = s.nominalBatteryVoltage {
        print("Nominal         : \(v) V / \(f) Hz / batería \(b) V")
    }
}

/// Diagnóstico del comando `T`: ¿lo acepta la UPS?, ¿marca b2?, ¿pasa a batería (b7)?,
/// ¿cuánto cae el voltaje?, ¿vuelve sola a la red?
func runBatteryTest() throws {
    let before = try ups.statusSync()
    guard !before.onBattery else { fail("Hay un corte de luz en curso: no se envía T.") }
    print("Antes: bits=\(before.statusBitsString) bat=\(String(format: "%.2f", before.batteryVoltage)) V "
        + "consumo=\(before.loadPercent)% salida=\(before.outputVoltage) V")
    print("Enviando T…")
    let reply: String
    do {
        let r = try ups.transport.send("T", expectReply: true, timeout: 1.5)
        reply = "«" + String(decoding: r.filter { $0 != 0x0D && $0 != 0x00 }, as: UTF8.self) + "»"
    } catch TransportError.timeout {
        reply = "ninguna"
    }
    print("Respuesta a T: \(reply)\n")
    print("  t    bits      b2 test  b7 batería  bat V   consumo  salida")

    var sawTest = false, sawBattery = false, sawLow = false, sawFault = false
    var minBattery = before.batteryVoltage
    var endedAt: Int?
    for t in 1...30 {
        Thread.sleep(forTimeInterval: 1)
        guard let s = try? ups.statusSync() else { print(String(format: "%3d s  (sin lectura)", t)); continue }
        sawTest = sawTest || s.testInProgress
        sawBattery = sawBattery || s.onBattery
        sawLow = sawLow || s.batteryLow
        sawFault = sawFault || s.upsFault
        minBattery = min(minBattery, s.batteryVoltage)
        if (sawTest || sawBattery) && !s.testInProgress && !s.onBattery && endedAt == nil { endedAt = t }
        print(String(format: "%3d s  %@  %@       %@          %5.2f   %3d%%     %5.1f V",
                     t, s.statusBitsString, s.testInProgress ? "sí" : "no", s.onBattery ? "sí" : "no",
                     s.batteryVoltage, s.loadPercent, s.outputVoltage))
        if let endedAt, t >= endedAt + 3 { break }
    }

    print("\nResumen:")
    print("  Respuesta a T:            \(reply)")
    print("  Bit de test (b2):         \(sawTest ? "sí" : "no")")
    print("  Pasó a batería (b7):      \(sawBattery ? "sí" : "no")")
    print("  Batería baja / falla:     \(sawLow ? "sí" : "no") / \(sawFault ? "sí" : "no")")
    print("  Voltaje mínimo:           \(String(format: "%.2f V (antes %.2f V, caída %.2f V)", minBattery, before.batteryVoltage, before.batteryVoltage - minBattery))")
    print("  Volvió a la red:          \(endedAt.map { "sí, a los \($0) s" } ?? (sawTest || sawBattery ? "no en 30 s" : "—"))")
    let accepted = sawTest || sawBattery
    print("  Conclusión:               \(accepted ? "la UPS admite el test de batería" : "la UPS no hizo el test (no lo admite o lo ignoró)")")
}

var args = Array(CommandLine.arguments.dropFirst())
var json = false
var loop: Double?
var raw: String?
var beeper: Bool?
var batteryTest = false

while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--json": json = true
    case "--loop":
        guard let v = args.first.flatMap(Double.init), v > 0 else { fail("--loop requiere segundos") }
        args.removeFirst()
        loop = v
    case "raw":
        guard !args.isEmpty else { fail("raw requiere un comando, p. ej. `upsctl raw M`") }
        raw = args.removeFirst()
    case "beeper":
        switch args.first {
        case "on": beeper = true
        case "off": beeper = false
        default: fail("beeper requiere on u off")
        }
        args.removeFirst()
    case "battery-test": batteryTest = true
    case "-h", "--help":
        print("Uso: upsctl [--json] [--loop SEG] | upsctl raw COMANDO | upsctl beeper on|off | upsctl battery-test")
        exit(0)
    default: fail("Argumento desconocido: \(a)")
    }
}

let ups = ForzaUPS()
ups.start()
let waitUntil = Date(timeIntervalSinceNow: 3)
while !ups.isConnected && Date() < waitUntil { Thread.sleep(forTimeInterval: 0.05) }
guard ups.isConnected else { fail("No se encontró la UPS (VID 0665 / PID 5161). ¿Está conectado el dock?") }

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let stamp = DateFormatter()
stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"

do {
    if let raw {
        let reply = try ups.rawSync(raw)
        print("hex  : \(reply.hexString)")
        print("ascii: \(String(decoding: reply.map { (0x20...0x7e).contains($0) ? $0 : UInt8(ascii: ".") }, as: UTF8.self))")
        exit(0)
    }
    if batteryTest {
        try runBatteryTest()
        exit(0)
    }
    if let beeper {
        let now = try ups.setBeeperSync(enabled: beeper)
        print("Alarma sonora: \(now ? "activada" : "desactivada")")
        exit(now == beeper ? 0 : 1)
    }
    if !json { print("Protocolo: \(try ups.protocolVariantSync())\n") }
    while true {
        let s = try ups.statusSync()
        if json {
            var obj = try JSONSerialization.jsonObject(with: encoder.encode(s)) as! [String: Any]
            obj["time"] = stamp.string(from: Date())
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        } else {
            printStatus(s)
        }
        guard let loop else { break }
        Thread.sleep(forTimeInterval: loop)
        if !json { print(String(repeating: "-", count: 50)) }
    }
} catch {
    fail("No pude comunicarme con la UPS: \(error)")
}
