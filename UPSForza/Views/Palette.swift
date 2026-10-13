import AppKit
import SwiftUI

/// Colores de estado de la app. Son más oscuros y sobrios que `.green`,
/// `.orange` y `.red` del sistema, que en modo oscuro se ven muy claros.
/// Los que se usan como texto se adaptan al modo claro y oscuro para mantener el contraste.
extension Color {
    /// Batería OK / red eléctrica.
    static let batteryGreen = Color(red: 0.118, green: 0.620, blue: 0.290)        // #1E9E4A

    /// En batería / atención. Ámbar profundo; un poco más oscuro en modo claro
    /// para que se lea como texto sobre fondo blanco.
    static let warningAmber = Color(light: 0xB86E00, dark: 0xD98A00)

    /// Apagado / batería baja / falla. Rojo profundo con buen contraste para texto blanco.
    static let dangerRed = Color(light: 0xB3261E, dark: 0xC62828)

    /// Gráficos del historial (validados con el chequeo de paleta en claro y oscuro):
    /// tiempo sin luz y activaciones del AVR.
    static let chartOutage = Color(light: 0xB86E00, dark: 0xC98000)
    static let chartAVR = Color(light: 0x0A64C8, dark: 0x3B8EEA)

    /// Panel: entrada y salida de la UPS (par validado, también con daltonismo).
    static let chartInput = Color(light: 0x0A64C8, dark: 0x3B8EEA)
    static let chartOutput = Color(light: 0xC2457A, dark: 0xD9609A)

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Botón de color sólido. A diferencia de `.borderedProminent`, no se desatura
/// cuando la ventana no está activa (el panel de la barra de menús nunca lo está).
struct SolidButtonStyle: ButtonStyle {
    enum Kind { case destructive, secondary }

    var kind: Kind = .destructive
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .body.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(kind == .destructive ? Color.white : Color.primary)
            .padding(.horizontal, large ? 18 : 12)
            .padding(.vertical, large ? 8 : 5)
            .background(background(pressed: configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: large ? 9 : 7, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: large ? 9 : 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: large ? 9 : 7, style: .continuous))
    }

    private func background(pressed: Bool) -> AnyShapeStyle {
        switch kind {
        case .destructive: AnyShapeStyle(Color.dangerRed.opacity(pressed ? 0.75 : 1))
        case .secondary: AnyShapeStyle(Color.primary.opacity(pressed ? 0.16 : 0.08))
        }
    }
}

extension ButtonStyle where Self == SolidButtonStyle {
    static func solid(_ kind: SolidButtonStyle.Kind = .destructive, large: Bool = false) -> SolidButtonStyle {
        SolidButtonStyle(kind: kind, large: large)
    }
}
