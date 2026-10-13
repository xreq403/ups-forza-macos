#!/usr/bin/env swift
// Genera el AppIcon de macOS a partir del logo SVG de Forza.
// Cada tamaño se renderiza desde el vector (no se reescala un PNG).
//
//   swift scripts/make-app-icon.swift Support/forza-logo.svg UPSForza/Assets.xcassets/AppIcon.appiconset
//   swift scripts/make-app-icon.swift Support/forza-logo.svg preview.png [blue|light]   (solo 1024 px)
//
// Variantes: "blue" (por defecto) = fondo azul Forza con la F blanca;
//            "light" = fondo claro con la F en azul Forza.

import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let logo = NSImage(contentsOfFile: args[1]) else {
    print("Uso: make-app-icon.swift LOGO.svg (DIR.appiconset | ARCHIVO.png) [blue|light]")
    exit(1)
}
let output = URL(fileURLWithPath: args[2])
let variant = args.count > 3 ? args[3] : "blue"

let brand = NSColor(srgbRed: 0x00 / 255.0, green: 0x85 / 255.0, blue: 0xCB / 255.0, alpha: 1)

let background: NSGradient
let foreground: NSColor
let plateBase: NSColor   // relleno bajo el degradado (solo se ve en la sombra)
switch variant {
case "light":
    background = NSGradient(starting: .white, ending: NSColor(srgbRed: 0.91, green: 0.93, blue: 0.96, alpha: 1))!
    foreground = brand
    plateBase = .white
default:
    background = NSGradient(
        starting: NSColor(srgbRed: 0.14, green: 0.64, blue: 0.91, alpha: 1),
        ending: NSColor(srgbRed: 0.00, green: 0.40, blue: 0.69, alpha: 1)
    )!
    foreground = .white
    plateBase = brand
}

/// El logo recoloreado, dibujado desde el vector a la resolución de destino.
func tintedLogo(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        logo.draw(in: rect)
        foreground.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

/// Plantilla de íconos de macOS: lienzo de 1024, placa de 824 con esquinas
/// redondeadas (radio ~185) y sombra suave hacia abajo.
func render(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: s, height: s)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let k = s / 1024
    let tile = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let plate = NSBezierPath(roundedRect: tile, xRadius: 185 * k, yRadius: 185 * k)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -10 * k)
    shadow.shadowBlurRadius = 20 * k
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    plateBase.setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()

    background.draw(in: plate, angle: -90)   // de arriba hacia abajo

    let side = tile.width * 0.80
    let logoRect = NSRect(x: (s - side) / 2, y: (s - side) / 2, width: side, height: side)
    tintedLogo(size: side).draw(in: logoRect)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if output.pathExtension == "png" {
    try render(pixels: 1024).write(to: output)
    print("OK: \(output.path)")
    exit(0)
}

let fm = FileManager.default
try fm.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: output.appending(path: name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appending(path: "Contents.json"))
print("OK: \(images.count) imágenes en \(output.path)")
