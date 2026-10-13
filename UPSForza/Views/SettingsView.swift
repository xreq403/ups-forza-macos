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
    @AppStorage(SettingsKey.batteryTestIntervalDays) private var batteryTestDays = 0

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

            DaemonSection()

            RecoverySection()

            Section("Sistema") {
                LoginItemToggle()
                LabeledContent("Notificaciones") {
                    Button("Enviar prueba") { monitor.sendTestNotification() }
                }
                LabeledContent {
                    ClearHistoryButton()
                } label: {
                    Text("Datos guardados")
                    Text("Historial de cortes y AVR, y registros de texto.")
                }
                LabeledContent("Registro") {
                    Button("Mostrar en Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([monitor.logURL])
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
                BatteryTestRow()
                Picker(selection: $batteryTestDays) {
                    Text("Desactivado").tag(0)
                    Text("Cada semana").tag(7)
                    Text("Cada mes").tag(30)
                } label: {
                    Text("Test de batería automático")
                    Text("Con luz estable, la UPS alimenta la Mac ~6 s desde la batería. Avisa solo si hay falla o desgaste.")
                }
                CalibrationRow()
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
        // El formulario agrupado tiene scroll propio: alto acotado en vez de crecer
        // con el contenido. Se puede agrandar hasta el máximo.
        // El tamaño lo maneja la ventana (ResizableWindow): la vista solo se adapta.
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .background(ResizableWindow(
            initialSize: NSSize(width: 480, height: 820),
            minSize: NSSize(width: 480, height: 420),
            maxSize: NSSize(width: 720, height: 980),
            autosaveName: "UPSForzaSettingsWindow"
        ))
    }
}

/// Registra la app como ítem de inicio de sesión (Ajustes > General > Items de inicio).
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

/// Servicio en segundo plano (daemon root): estado, activación y aprobación.
struct DaemonSection: View {
    @Environment(UPSMonitor.self) private var monitor

    var body: some View {
        let daemon = monitor.daemon
        Section {
            LabeledContent {
                switch daemon.state {
                case .enabled:
                    Button("Desactivar") { Task { await daemon.unregister() } }
                case .requiresApproval:
                    Button("Abrir Ajustes del Sistema") { daemon.openSystemSettings() }
                case .notRegistered, .notFound:
                    Button("Activar") { daemon.register() }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                    Text(stateText)
                }
                Text(detailText)
                if let error = daemon.lastError ?? (monitor.backendKind == .daemon ? monitor.backendError : nil) {
                    Text(error).foregroundStyle(Color.dangerRed)
                }
            }
        } header: {
            Text("Servicio en segundo plano")
        } footer: {
            Text("Con el servicio activo, la UPS se vigila con privilegios de administrador aunque no haya ninguna sesión abierta, y si una app bloquea el apagado, se fuerza a los 90 s. Sin el servicio, esta app vigila la UPS mientras está abierta.")
        }
    }

    private var stateText: String {
        switch monitor.daemon.state {
        case .enabled: monitor.backendError == nil ? "Activo" : "Activo, sin respuesta"
        case .requiresApproval: "Esperando aprobación"
        case .notRegistered: "Desactivado"
        case .notFound: "No disponible"
        }
    }

    private var detailText: String {
        switch monitor.daemon.state {
        case .enabled: "La UPS la vigila el servicio."
        case .requiresApproval: "Apruébalo en Ajustes del Sistema > General > Ítems de inicio y extensiones."
        case .notRegistered: "La UPS la vigila esta app mientras está abierta."
        case .notFound: "No se encontró el servicio dentro de la app."
        }
    }

    private var dotColor: Color {
        switch monitor.daemon.state {
        case .enabled: monitor.backendError == nil ? .batteryGreen : .warningAmber
        case .requiresApproval: .warningAmber
        case .notRegistered, .notFound: .secondary
        }
    }
}
