import SwiftUI

/// Botón para borrar los datos guardados. Abre una hoja de confirmación
/// (la acción no se puede deshacer) donde se elige qué borrar.
struct ClearHistoryButton: View {
    @Environment(UPSMonitor.self) private var monitor

    var label = "Borrar datos…"
    /// En una barra de herramientas: con ícono de papelera.
    var compact = false

    @State private var confirming = false
    @State private var done = false

    var body: some View {
        HStack(spacing: 8) {
            if done {
                Label("Borrado", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.batteryGreen)
                    .transition(.opacity)
            }
            Button {
                confirming = true
            } label: {
                if compact { Label(label, systemImage: "trash") } else { Text(label) }
            }
        }
        .sheet(isPresented: $confirming) {
            ClearDataSheet { includeLogs in
                try await monitor.clearHistory(includeLogs: includeLogs)
                withAnimation { done = true }
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { done = false }
                }
            }
        }
    }
}

/// Confirmación del borrado: qué borrar, advertencia y botones Cancelar / Borrar.
private struct ClearDataSheet: View {
    enum Scope: Hashable {
        case history
        case historyAndLogs
    }

    let perform: (_ includeLogs: Bool) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope = .history
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(Color.dangerRed.opacity(0.15))
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.dangerRed)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text("¿Borrar los datos guardados?")
                        .font(.headline)
                    Text("Se eliminan los cortes de luz, las activaciones del AVR y el voltaje diario de la red. Los ajustes no se modifican.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Qué borrar", selection: $scope) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Solo el historial")
                    Text("Los registros de texto se conservan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(Scope.history)
                .padding(.bottom, 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text("El historial y los registros de texto")
                    Text("También se vacían los registros del servicio y de la app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(Scope.historyAndLogs)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .padding(.leading, 54)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.dangerRed)
            }

            HStack(spacing: 10) {
                Label("No se puede deshacer", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.solid(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Borrar") { clear() }
                    .buttonStyle(.solid())
            }
            .disabled(working)
        }
        .padding(24)
        .frame(width: 440)
    }

    private func clear() {
        working = true
        error = nil
        Task {
            do {
                try await perform(scope == .historyAndLogs)
                dismiss()
            } catch {
                self.error = "No se pudieron borrar los datos: \(error)"
                working = false
            }
        }
    }
}
