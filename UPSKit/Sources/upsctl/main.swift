// upsctl — equivalente en Swift de forza_ups.py, para probar el transporte HID.
//
//   swift run upsctl              estado una vez
//   swift run upsctl --json       salida en JSON
//   swift run upsctl --loop 3     refresca cada 3 s
//   swift run upsctl raw M        envía un comando y muestra la respuesta cruda
//   swift run upsctl beeper off   desactiva la alarma sonora (on para activarla)

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

var args = Array(CommandLine.arguments.dropFirst())
var json = false
var loop: Double?
var raw: String?
var beeper: Bool?

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
    case "-h", "--help":
        print("Uso: upsctl [--json] [--loop SEG] | upsctl raw COMANDO | upsctl beeper on|off")
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
