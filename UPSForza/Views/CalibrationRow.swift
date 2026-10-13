import Charts
import SwiftUI
import UPSKit

/// Ajustes → UPS → Calibración de autonomía: último resultado y botón que abre el asistente.
struct CalibrationRow: View {
    @Environment(UPSMonitor.self) private var monitor
    @State private var showingSheet = false

    var body: some View {
        LabeledContent {
            Button(monitor.calibration == nil ? "Calibrar…" : "Ver progreso…") { showingSheet = true }
                .disabled(monitor.calibration == nil && monitor.link != .connected)
        } label: {
            Text("Calibración de autonomía")
            Text(detail)
                .foregroundStyle(monitor.calibration == nil ? Color.secondary : Color.warningAmber)
        }
        .sheet(isPresented: $showingSheet) {
            CalibrationSheet()
        }
    }

    private var detail: String {
        if let c = monitor.calibration {
            switch c.phase {
            case .waitingForUnplug: return "En curso: esperando que desenchufes la UPS."
            case .discharging: return "En curso: registrando la descarga."
            case .waitingForPower: return "Terminó la descarga: vuelve a enchufar la UPS."
            }
        }
        guard let last = monitor.lastCalibration else {
            return "Mide cuánto dura la batería con tu consumo, con una descarga controlada desenchufando la UPS."
        }
        let when = last.start.formatted(.relative(presentation: .named))
        guard let fit = last.fit, let minutes = last.projectedMinutes(to: last.floorVoltage) else {
            return "Última (\(when)): descarga corta, sin datos suficientes."
        }
        return String(format: "Última (%@): %.3f V/min con ~%.0f W · ~%d min hasta %.1f V.",
                      when, fit.slope, last.averageWatts, Int(minutes.rounded()), last.floorVoltage)
    }
}

// MARK: - Asistente

/// Asistente de calibración en una hoja: explicación → desenchufar → descarga →
/// volver a enchufar → resultado. La prueba la lleva el monitor (daemon o local),
/// así que sigue aunque se cierre la hoja.
private struct CalibrationSheet: View {
    @Environment(UPSMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    @AppStorage("calibrationMaxMinutes") private var maxMinutes = 30
    @State private var startError: String?
    @State private var starting = false
    /// Desde cuándo sigue esta hoja una calibración (para mostrar su resultado al terminar).
    @State private var watchingSince: Date?

    private enum Stage {
        case explain
        case live(CalibrationState)
        case result(CalibrationRecord)
    }

    private var stage: Stage {
        if let c = monitor.calibration { return .live(c) }
        if let since = watchingSince, let last = monitor.lastCalibration, last.end >= since { return .result(last) }
        return .explain
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

                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.headline)
                    content
                }
            }
            buttons
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { if monitor.calibration != nil { follow(monitor.calibration!) } }
        .onChange(of: monitor.calibration) { _, c in if let c, watchingSince == nil { follow(c) } }
    }

    private func follow(_ c: CalibrationState) {
        switch c.phase {
        case .waitingForUnplug: watchingSince = .now.addingTimeInterval(-1)
        case .discharging(let start, _), .waitingForPower(let start, _, _): watchingSince = start.addingTimeInterval(-1)
        }
    }

    // MARK: Encabezado

    private var title: String {
        switch stage {
        case .explain: "Calibración de autonomía"
        case .live(let c):
            switch c.phase {
            case .waitingForUnplug: "Desenchufa la UPS de la pared"
            case .discharging: "Registrando la descarga…"
            case .waitingForPower: "Vuelve a enchufar la UPS"
            }
        case .result(let r): r.isUsable ? "Calibración guardada" : "Descarga demasiado corta"
        }
    }

    private var iconName: String {
        switch stage {
        case .explain: "gauge.with.needle"
        case .live(let c):
            switch c.phase {
            case .waitingForUnplug: "powerplug"
            case .discharging: "battery.50percent"
            case .waitingForPower: "powerplug.fill"
            }
        case .result(let r): r.isUsable ? "checkmark" : "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch stage {
        case .explain: .accentColor
        case .live(let c):
            if case .waitingForPower = c.phase { .warningAmber } else { .accentColor }
        case .result(let r): r.isUsable ? .batteryGreen : .warningAmber
        }
    }

    // MARK: Contenido

    @ViewBuilder private var content: some View {
        switch stage {
        case .explain: explain
        case .live(let c): live(c)
        case .result(let r): result(r)
        }
    }

    @ViewBuilder private var explain: some View {
        Text("Mide cómo baja el voltaje de la batería con el consumo real de tu Mac. Con eso se estima cuántos minutos de autonomía quedan durante un corte.")
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
            step(1, "Al iniciar, desenchufa la UPS de la pared (tienes 5 minutos). La Mac sigue encendida.")
            step(2, String(format: "La app registra el voltaje y el consumo. Se detiene sola en %.1f V (~30 %%) o al cumplir la duración máxima.", Calibration.floorVoltage))
            step(3, "Vuelve a enchufar la UPS cuando te avise. El resultado se guarda al volver la luz.")
        }
        .font(.callout)
        Picker("Duración máxima", selection: $maxMinutes) {
            ForEach(Calibration.durationOptions, id: \.self) { Text("\($0) min").tag($0) }
        }
        .fixedSize()
        Text("Durante la descarga se suspenden los umbrales de % y de tiempo; la batería baja de la UPS sigue apagando la Mac. Al terminar vuelven tus umbrales: si no enchufas la UPS, la Mac se apaga como en un corte. Con poco consumo la batería baja despacio: conviene 30 minutos o más.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let blocker {
            Label(blocker, systemImage: "info.circle").font(.callout).foregroundStyle(Color.warningAmber)
        }
        if let startError {
            Label(startError, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Color.dangerRed)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 18, height: 18)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Por qué no se puede iniciar ahora (la validación final la hace el monitor).
    private var blocker: String? {
        guard monitor.link == .connected, let s = monitor.status else { return "La UPS no está conectada." }
        if s.onBattery { return "Hay un corte de luz en curso." }
        if s.charging {
            return String(format: "La batería se está recargando (%.2f V). Espera a que esté llena.", s.batteryVoltage)
        }
        if monitor.batteryTestRunning { return "Hay un test de batería en curso." }
        return nil
    }

    @ViewBuilder private func live(_ c: CalibrationState) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                switch c.phase {
                case .waitingForUnplug(let deadline):
                    Text("Desenchufa el cable de la UPS de la pared. La prueba empieza cuando la UPS pase a batería.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Se cancela sola en \(max(deadline.timeIntervalSince(context.date), 0).durationText) si no se desenchufa.")
                        .font(.callout).foregroundStyle(.secondary)

                case .discharging(let start, let deadline):
                    let elapsed = context.date.timeIntervalSince(start)
                    ProgressView(value: min(elapsed / deadline.timeIntervalSince(start), 1)) {
                        Text("\(elapsed.durationText) de \(c.maxMinutes) min")
                            .font(.callout).monospacedDigit()
                    }
                    readings(c)
                    DischargeChart(samples: c.samples, fit: Calibration.fit(c.samples))
                    Text(String(format: "Se detiene sola en %.1f V. Puedes cerrar esta ventana: la prueba sigue.", Calibration.floorVoltage))
                        .font(.callout).foregroundStyle(.secondary)

                case .waitingForPower(let start, let stopped, let reason):
                    Text("\(reason.description) tras \(stopped.timeIntervalSince(start).durationText). Enchufa la UPS a la pared: el resultado se guarda cuando vuelva la luz.")
                        .fixedSize(horizontal: false, vertical: true)
                    readings(c)
                    Text("Ya volvieron tus umbrales de apagado: si la UPS sigue desenchufada, la Mac se apagará como en un corte.")
                        .font(.callout).foregroundStyle(Color.warningAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func readings(_ c: CalibrationState) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            if let last = c.samples.last {
                row("Batería", String(format: "%.2f V", last.volts))
                row("Consumo", "\(last.load) % (~\(last.load * UPSStatus.ratedWatts / 100) W)")
            }
            if let fit = Calibration.fit(c.samples) {
                row("Pendiente", String(format: "%.3f V/min", fit.slope))
            } else {
                row("Pendiente", "se calcula tras \(Int((Calibration.settleSeconds + Calibration.minFitSeconds) / 60)) min")
            }
        }
        .font(.callout)
    }

    @ViewBuilder private func result(_ r: CalibrationRecord) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            row("Duración", r.duration.durationText)
            row("Batería", String(format: "%.2f V con luz → %.2f V mín.", r.voltageBefore, r.voltageMin))
            row("Consumo promedio", String(format: "%.1f %% (~%.0f W)", r.averageLoad, r.averageWatts))
            row("Fin", r.stopReason.description)
            if let fit = r.fit {
                row("Pendiente", String(format: "%.3f V/min", fit.slope))
                if let minutes = r.projectedMinutes(to: r.floorVoltage) {
                    row(String(format: "Hasta %.1f V", r.floorVoltage), "~\(Int(minutes.rounded())) min desde batería llena")
                }
            }
        }
        .font(.callout)
        DischargeChart(samples: r.samples, fit: r.fit)
        Text(r.isUsable
             ? "La autonomía se extrapola en línea recta: cerca del final la batería cae más rápido, así que es una cota optimista. Con otro consumo, el tiempo cambia en proporción."
             : "Hacen falta al menos \(Int((Calibration.settleSeconds + Calibration.minFitSeconds) / 60)) minutos en batería para calcular la pendiente. Vuelve a intentarlo cuando la batería esté llena.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    // MARK: Botones

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            if starting { ProgressView().controlSize(.small) }
            Spacer()
            switch stage {
            case .explain:
                Button("Cancelar") { dismiss() }
                    .buttonStyle(.solid(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Iniciar") { start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocker != nil || starting)
            case .live(let c):
                switch c.phase {
                case .waitingForUnplug:
                    Button("Cancelar prueba") { Task { await monitor.cancelCalibration() } }
                        .buttonStyle(.solid(.secondary))
                case .discharging:
                    Button("Detener ahora") { Task { await monitor.cancelCalibration() } }
                        .buttonStyle(.solid(.secondary))
                case .waitingForPower:
                    Button("Guardar sin esperar") { Task { await monitor.cancelCalibration() } }
                        .buttonStyle(.solid(.secondary))
                }
                Button("Cerrar") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .result:
                Button("Cerrar") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func start() {
        starting = true
        startError = nil
        Task {
            watchingSince = .now
            startError = await monitor.startCalibration(maxMinutes: maxMinutes)
            if startError != nil { watchingSince = nil }
            starting = false
        }
    }
}

// MARK: - Gráfico

/// Voltaje de la batería durante la descarga y la recta ajustada (sin la caída inicial).
private struct DischargeChart: View {
    let samples: [CalibrationSample]
    let fit: Calibration.Fit?

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, s in
                LineMark(x: .value("Minutos", s.minutes), y: .value("V", s.volts), series: .value("Serie", "Medido"))
                    .foregroundStyle(by: .value("Serie", "Medido"))
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let fit, let last = samples.last {
                let x0 = Calibration.settleSeconds / 60
                ForEach([x0, last.minutes], id: \.self) { m in
                    LineMark(x: .value("Minutos", m), y: .value("V", fit.intercept - fit.slope * m), series: .value("Serie", "Tendencia"))
                        .foregroundStyle(by: .value("Serie", "Tendencia"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
        }
        .chartForegroundStyleScale(["Medido": Color.batteryGreen, "Tendencia": Color.secondary])
        .chartLegend(position: .top, alignment: .leading)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxisLabel("minutos")
        .chartXAxis { AxisMarks { AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
        .chartYAxis { AxisMarks(position: .leading) { AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
        .frame(height: 150)
    }
}
