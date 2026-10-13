import SwiftUI
import UPSKit

/// Ajustes > Recuperación tras un corte: que la Mac se encienda sola cuando vuelve
/// la luz (`pmset autorestart`, lo cambia el daemon root).
///
/// La NT-2402PRO no admite apagar su salida por comando (`S<n>` responde `N`, ver
/// spec.md §3.4), así que la Mac solo arranca sola si el corte agota la batería de la UPS.
struct RecoverySection: View {
    @Environment(UPSMonitor.self) private var monitor

    @State private var power: SystemPowerSettings?
    @State private var powerError: String?
    @State private var changingPower = false

    var body: some View {
        Section {
            Toggle(isOn: autoRestartBinding) {
                Text("Encender la Mac al volver la luz")
                Text(autoRestartCaption)
                if let powerError { Text(powerError).foregroundStyle(Color.dangerRed) }
            }
            .disabled(!(power?.canChange ?? false) || changingPower)
        } header: {
            Text("Recuperación tras un corte")
        } footer: {
            Text("La Mac arranca sola si el corte agota la batería de la UPS: la UPS corta su salida y la restablece al volver la luz. Si la luz vuelve antes, la Mac queda apagada y hay que encenderla a mano.")
        }
        .task(id: monitor.backendKind) { await loadPower() }
    }

    private var autoRestartCaption: String {
        guard let power else { return "Leyendo el ajuste de energía…" }
        if !power.canChange { return "Requiere el servicio en segundo plano activo." }
        return "Ajustes del Sistema > Energía > Arrancar automáticamente tras un corte de luz."
    }

    private var autoRestartBinding: Binding<Bool> {
        Binding(
            get: { power?.autoRestart ?? false },
            set: { on in
                changingPower = true
                Task {
                    do {
                        try await monitor.setAutoRestart(on)
                        powerError = nil
                    } catch {
                        powerError = String(describing: error)
                    }
                    await loadPower()
                    changingPower = false
                }
            }
        )
    }

    private func loadPower() async {
        do {
            power = try await monitor.powerSettings()
        } catch {
            powerError = String(describing: error)
        }
    }
}
