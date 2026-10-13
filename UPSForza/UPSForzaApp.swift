import SwiftUI
import UPSKit

@main
struct UPSForzaApp: App {
    @State private var monitor: UPSMonitor

    init() {
        AppSettings.registerDefaults()
        let monitor = UPSMonitor()
        monitor.start()
        _monitor = State(initialValue: monitor)
    }

    var body: some Scene {
        MenuBarExtra {
            StatusPopover()
                .environment(monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(monitor)
        }
    }
}

/// Ícono de la barra de menús: enchufe con luz, batería con % durante un corte,
/// triángulo de alerta ante batería baja, falla, aviso o sin comunicación.
struct MenuBarLabel: View {
    let monitor: UPSMonitor

    var body: some View {
        let (symbol, text) = content
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let text { Text(text).monospacedDigit() }
        }
    }

    private var content: (String, String?) {
        guard monitor.link == .connected, let s = monitor.status else {
            return ("exclamationmark.triangle", nil)
        }
        switch monitor.phase {
        case .warning, .shuttingDown:
            return ("exclamationmark.triangle.fill", "\(s.batteryPercent)%")
        default:
            break
        }
        if s.upsFault || s.batteryLow { return ("exclamationmark.triangle.fill", s.onBattery ? "\(s.batteryPercent)%" : nil) }
        guard s.onBattery else { return ("powerplug.fill", nil) }
        return (Self.batterySymbol(s.batteryPercent), "\(s.batteryPercent)%")
    }

    static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case 88...: "battery.100percent"
        case 63..<88: "battery.75percent"
        case 38..<63: "battery.50percent"
        case 13..<38: "battery.25percent"
        default: "battery.0percent"
        }
    }
}
