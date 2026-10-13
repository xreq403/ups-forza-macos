import ServiceManagement
import SwiftUI
import UPSKit

struct SettingsView: View {
    @Environment(UPSMonitor.self) private var monitor

    @AppStorage(SettingsKey.shutdownOnUPSLowBattery) private var onLowBattery = true
    @AppStorage(SettingsKey.minBatteryPercent) private var minPercent = 30
    @AppStorage(SettingsKey.maxMinutesOnBattery) private var maxMinutes = 10
    @AppStorage(SettingsKey.warningSeconds) private var warningSeconds = 60
    @AppStorage(SettingsKey.pollInterval) private var pollInterval = 5

    var body: some View {
        Form {
            Section {
                Toggle("Cuando la UPS indique batería baja", isOn: $onLowBattery)
                Picker("Cuando la batería baje de", selection: $minPercent) {
                    Text("Desactivado").tag(0)
                    ForEach([10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0) %").tag($0) }
                }
                Picker("Tras minutos sin luz", selection: $maxMinutes) {
                    Text("Desactivado").tag(0)
                    ForEach([2, 5, 10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Aviso previo", selection: $warningSeconds) {
                    ForEach([15, 30, 60, 120, 180], id: \.self) { Text("\($0) s").tag($0) }
                }
            } header: {
                Text("Apagar la Mac")
            } footer: {
                Text("Se apaga con lo primero que ocurra. El % es una estimación por voltaje: lo más confiable es la señal de batería baja de la UPS.")
            }

            Section("Monitoreo") {
                Picker("Consultar la UPS cada", selection: $pollInterval) {
                    ForEach([2, 5, 10, 30], id: \.self) { Text("\($0) s").tag($0) }
                }
            }

            Section("Sistema") {
                LoginItemToggle()
                LabeledContent("Notificaciones") {
                    Button("Enviar prueba") { monitor.sendTestNotification() }
                }
                LabeledContent("Registro") {
                    Button("Mostrar en Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([EventLog.shared.url])
                    }
                }
            }

            Section("UPS") {
                @Bindable var monitor = monitor
                Toggle(isOn: $monitor.beeperEnabled) {
                    Text("Alarma sonora")
                    Text("Se aplica a la UPS al abrir la app y cada vez que se reconecta. Desactivada, la UPS no pita en los cortes; las notificaciones de la Mac siguen llegando.")
                    if let error = monitor.beeperSyncError {
                        Text(error).foregroundStyle(Color.dangerRed)
                    }
                }
                LabeledContent("Modelo", value: "Forza NT-2402PRO")
                LabeledContent("Protocolo", value: monitor.protocolVariant.map { "Voltronic-QS-Hex (\($0))" } ?? "—")
                if let s = monitor.status, let v = s.nominalOutputVoltage, let f = s.nominalFrequency,
                   let b = s.nominalBatteryVoltage {
                    LabeledContent("Valores nominales", value: "\(v) V · \(f) Hz · batería \(b) V")
                }
                if let error = monitor.lastError, monitor.link != .connected {
                    LabeledContent("Último error", value: error)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Registra la app como ítem de inicio de sesión (Ajustes → General → Ítems de inicio).
struct LoginItemToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Toggle(isOn: $enabled) {
            Text("Abrir al iniciar sesión")
            if let error {
                Text(error).foregroundStyle(Color.dangerRed)
            }
        }
        .onChange(of: enabled) { _, newValue in
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                error = nil
            } catch {
                self.error = error.localizedDescription
                enabled = SMAppService.mainApp.status == .enabled
            }
        }
    }
}
