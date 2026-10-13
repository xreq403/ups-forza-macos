import SwiftUI
import UPSKit

/// Ajustes → UPS → Test de batería: último resultado y botón que abre el test en una hoja.
struct BatteryTestRow: View {
    @Environment(UPSMonitor.self) private var monitor
    @State private var showingTest = false

    var body: some View {
        LabeledContent {
            if monitor.batteryTestRunning {
                ProgressView().controlSize(.small)
            } else {
                Button("Probar ahora…") { showingTest = true }
                    .disabled(!canRun)
            }
        } label: {
            Text("Test de batería")
            Text(detail)
                .foregroundStyle(detailColor)
        }
        .sheet(isPresented: $showingTest) {
            BatteryTestSheet()
        }
    }

    private var canRun: Bool {
        monitor.link == .connected && monitor.status?.onBattery == false && monitor.phase == .online
    }

    private var detail: String {
        if monitor.batteryTestRunning { return "Probando… la UPS alimenta la Mac desde la batería unos segundos." }
        if !canRun && monitor.lastBatteryTest == nil { return "Solo con luz y la UPS conectada." }
        guard let t = monitor.lastBatteryTest else {
            return "Comprueba que la batería sostiene la carga. El primer test queda como referencia."
        }
        let when = t.start.formatted(.relative(presentation: .named))
        switch (t.outcome, t.health) {
        case (.failed, _):
            return "Último (\(when)): falla, la UPS indicó batería baja o falla."
        case (.notStarted, _):
            return "Último (\(when)): la UPS no inició el test."
        case (_, .degrading):
            return String(format: "Último (%@): desgaste, %.2f V (referencia %.2f V).", when, t.voltageMin, t.referenceVoltage ?? 0)
        case (_, .reference):
            return String(format: "Último (%@): %.2f V, caída %.2f V. Es la referencia.", when, t.voltageMin, t.drop)
        default:
            return String(format: "Último (%@): OK, %.2f V, caída %.2f V.", when, t.voltageMin, t.drop)
        }
    }

    private var detailColor: Color {
        guard let t = monitor.lastBatteryTest, !monitor.batteryTestRunning else { return .secondary }
        switch (t.outcome, t.health) {
        case (.failed, _): return .dangerRed
        case (_, .degrading): return .warningAmber
        default: return .secondary
        }
    }
}

/// Test de batería en una hoja: explicación → progreso → resultado.
private struct BatteryTestSheet: View {
    @Environment(UPSMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    enum Stage {
        case explain
        case running
        case done(BatteryTestRecord)
        case failed(String)
    }

    @State private var stage: Stage = .explain

    private var isRunning: Bool {
        if case .running = stage { true } else { false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(iconColor.opacity(0.15))
                    Image(systemName: iconName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline)
                    content
                }
            }

            HStack(spacing: 10) {
                if isRunning {
                    ProgressView().controlSize(.small)
                    Text("Probando… (unos segundos)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch stage {
                case .explain:
                    Button("Cancelar") { dismiss() }
                        .buttonStyle(.solid(.secondary))
                        .keyboardShortcut(.cancelAction)
                    Button("Iniciar test") { run() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                case .running:
                    EmptyView()
                case .done, .failed:
                    Button("Cerrar") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(isRunning)
    }

    // MARK: Contenido por etapa

    private var title: String {
        switch stage {
        case .explain: "Test de batería"
        case .running: "Probando la batería…"
        case .done(let t):
            switch (t.outcome, t.health) {
            case (.failed, _): "La batería no superó el test"
            case (.notStarted, _): "La UPS no inició el test"
            case (_, .degrading): "La batería muestra desgaste"
            case (_, .reference): "Test superado: referencia guardada"
            default: "Test superado"
            }
        case .failed: "No se pudo hacer el test"
        }
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .explain:
            Text("La UPS alimentará la Mac **desde la batería unos 6 segundos** y volverá sola a la red. Así se comprueba que la batería sostiene la carga.")
                .fixedSize(horizontal: false, vertical: true)
            Text(monitor.lastBatteryTest == nil
                 ? "Es el primer test: su resultado queda como referencia para detectar desgaste en el futuro."
                 : "El resultado se compara con el primer test superado (la referencia).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .running:
            Text("Midiendo el voltaje de la batería mientras alimenta la Mac.")
                .foregroundStyle(.secondary)
        case .done(let t):
            if t.outcome == .notStarted {
                Text("La UPS no marcó el test en curso. Vuelve a intentarlo en unos minutos.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    row("Voltaje antes", String(format: "%.2f V", t.voltageBefore))
                    row("Voltaje mínimo", String(format: "%.2f V", t.voltageMin))
                    row("Caída", String(format: "%.2f V", t.drop))
                    row("Consumo", "\(t.maxLoadPercent) %")
                    row("Duración", t.duration.durationText)
                    if let ref = t.referenceVoltage, t.health != .reference {
                        row("Referencia", String(format: "%.2f V", ref))
                    }
                }
                .font(.callout)
                Text(verdict(t))
                    .font(.callout)
                    .foregroundStyle(t.health == .degrading || t.outcome == .failed ? Color.dangerRed : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            Text(message).foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func verdict(_ t: BatteryTestRecord) -> String {
        switch (t.outcome, t.health) {
        case (.failed, _):
            "La UPS indicó batería baja o falla. Conviene revisar o cambiar las baterías."
        case (_, .degrading):
            String(format: "Cayó %.2f V más que la referencia. La batería se está desgastando.",
                   (t.referenceVoltage ?? t.voltageMin) - t.voltageMin)
        case (_, .reference):
            "Los próximos tests se compararán con este."
        default:
            "Dentro de lo esperado respecto de la referencia."
        }
    }

    private var iconName: String {
        switch stage {
        case .explain, .running: "minus.plus.batteryblock"
        case .done(let t): t.outcome == .passed && t.health != .degrading ? "checkmark" : "exclamationmark.triangle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch stage {
        case .explain, .running: .accentColor
        case .done(let t):
            switch (t.outcome, t.health) {
            case (.failed, _): .dangerRed
            case (_, .degrading), (.notStarted, _): .warningAmber
            default: .batteryGreen
            }
        case .failed: .warningAmber
        }
    }

    private func run() {
        stage = .running
        Task {
            let response = await monitor.runBatteryTest()
            if let record = response.record {
                stage = .done(record)
            } else {
                stage = .failed(response.error ?? "Error desconocido.")
            }
        }
    }
}
