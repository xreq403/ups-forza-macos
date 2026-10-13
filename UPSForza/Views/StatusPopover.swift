import SwiftUI
import UPSKit

struct StatusPopover: View {
    @Environment(UPSMonitor.self) private var monitor
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if monitor.phase.isWarning {
                WarningBanner()
            }

            if let s = monitor.status {
                BatteryCard(status: s, outageStart: monitor.phase.outageStart)
                    .opacity(monitor.link == .connected ? 1 : 0.5)
                MetricsGrid(status: s)
                    .opacity(monitor.link == .connected ? 1 : 0.5)
            } else {
                searchingPlaceholder
            }

            // Módulos al estilo del Centro de Control, en la misma grilla de 2 columnas.
            HStack(spacing: 8) {
                BeeperToggleTile()
                HistoryTile {
                    NSApp.activate()
                    openWindow(id: "history")
                }
            }

            if let s = monitor.status {
                FlagsRow(status: s)
            }

            Divider()
                .padding(.horizontal, -4)
            HStack {
                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Label("Ajustes", systemImage: "gearshape")
                }
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Salir", systemImage: "power")
                }
            }
            .buttonStyle(FooterButtonStyle())
            .padding(.horizontal, -6)
            .padding(.bottom, -4)
        }
        .padding(16)
        .frame(width: 330)
    }

    // MARK: - Secciones

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Forza NT-2402PRO")
                .font(.headline)
            Spacer()
            StatusPill(phase: monitor.phase, link: monitor.link)
        }
    }

    private var searchingPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "cable.connector")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(monitor.link == .searching ? "Buscando la UPS…" : "Sin comunicación con la UPS")
                .font(.callout.weight(.medium))
            Text("Conecta el cable USB de la UPS al dock.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Componentes

struct StatusPill: View {
    let phase: PowerPhase
    let link: LinkState

    var body: some View {
        let (text, color) = content
        Label(text, systemImage: "circle.fill")
            .labelStyle(PillLabelStyle(color: color))
    }

    private var content: (String, Color) {
        if link != .connected { return (link == .searching ? "Buscando" : "Sin conexión", .gray) }
        switch phase {
        case .unknown: return ("…", .gray)
        case .online: return ("Red eléctrica", .green)
        case .onBattery: return ("En batería", .warningAmber)
        case .warning: return ("Apagando", .dangerRed)
        case .shuttingDown: return ("Apagado enviado", .dangerRed)
        }
    }
}

private struct PillLabelStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            configuration.title
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
    }
}

struct BatteryCard: View {
    let status: UPSStatus
    let outageStart: Date?

    private var tint: Color {
        if status.batteryLow || status.batteryPercent < 25 { return .dangerRed }
        if status.onBattery { return .warningAmber }
        return .batteryGreen
    }

    var body: some View {
        HStack(spacing: 16) {
            Gauge(value: Double(status.batteryPercent), in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                Text("\(status.batteryPercent)")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .scaleEffect(1.25)
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(status.onBattery ? "Funcionando con batería" : "Batería")
                    .font(.subheadline.weight(.semibold))
                Text(String(format: "%.2f V", status.batteryVoltage))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let outageStart {
                    Label {
                        Text("Sin luz hace \(outageStart, style: .timer)")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "bolt.slash.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(Color.warningAmber)
                } else if status.charging {
                    Label("Recargando", systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(Color.batteryGreen)
                } else {
                    Label("Carga completa", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct MetricsGrid: View {
    let status: UPSStatus

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                MetricTile(title: "Entrada", value: String(format: "%.1f V", status.inputVoltage), symbol: "arrow.down.to.line")
                MetricTile(title: "Salida", value: String(format: "%.1f V", status.outputVoltage), symbol: "arrow.up.to.line")
            }
            GridRow {
                MetricTile(title: "Consumo", value: "\(status.loadPercent) %", detail: "~\(status.estimatedWatts) W",
                           symbol: "gauge.with.dots.needle.33percent")
                    .help("Potencia que usan los equipos conectados, estimada sobre los \(UPSStatus.ratedWatts) W de la UPS")
                MetricTile(title: "Frecuencia", value: String(format: "%.1f Hz", status.frequency), symbol: "waveform.path")
            }
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Control al estilo del Centro de Control: círculo azul con campana cuando la
/// alarma está activa, gris con campana tachada cuando está silenciada.
/// Comparte el estado con el toggle de Ajustes (`UPSMonitor.beeperEnabled`).
struct BeeperToggleTile: View {
    @Environment(UPSMonitor.self) private var monitor

    var body: some View {
        let on = monitor.beeperEnabled
        Button {
            monitor.beeperEnabled.toggle()
        } label: {
            ModuleTile(
                symbol: on ? "bell.fill" : "bell.slash.fill",
                active: on,
                title: "Alarma",
                subtitle: subtitle,
                subtitleColor: monitor.beeperSyncError == nil ? .secondary : .dangerRed
            ) {
                if isApplying { ProgressView().controlSize(.small) }
            }
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: on)
        .help(on ? "Silenciar la alarma de la UPS" : "Activar la alarma de la UPS")
        .accessibilityLabel("Alarma sonora")
        .accessibilityValue(on ? "Activada" : "Silenciada")
    }

    /// El ajuste cambió pero la UPS todavía no lo refleja.
    private var isApplying: Bool {
        monitor.beeperSyncError == nil && monitor.link == .connected
            && (monitor.beeperSyncing || monitor.status?.beeperOn != monitor.beeperEnabled)
    }

    private var subtitle: String {
        if monitor.beeperSyncError != nil { return "No se pudo aplicar" }
        if isApplying { return "Aplicando…" }
        return monitor.beeperEnabled ? "Activada" : "Silenciada"
    }
}

/// Abre la ventana del historial.
struct HistoryTile: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ModuleTile(symbol: "chart.xyaxis.line", active: false, title: "Panel", subtitle: "En vivo e historial") {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .help("Gráficos en vivo e historial de cortes y AVR")
    }
}

/// Módulo al estilo del Centro de Control: círculo con ícono (relleno con el color
/// de acento si está activo), título y subtítulo, y un accesorio opcional a la derecha.
struct ModuleTile<Accessory: View>: View {
    let symbol: String
    let active: Bool
    let title: String
    let subtitle: String
    var subtitleColor: Color = .secondary
    @ViewBuilder var accessory: Accessory

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Color.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(hovering ? 0.8 : 0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Botón del pie del panel: ícono + texto discretos, con fondo al pasar el mouse.
struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FooterButtonBody(configuration: configuration)
    }

    private struct FooterButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.callout)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

/// Solo muestra lo que se sale de lo normal.
struct FlagsRow: View {
    let status: UPSStatus

    var body: some View {
        let flags = items
        if !flags.isEmpty {
            HStack(spacing: 6) {
                ForEach(flags, id: \.0) { text, color in
                    Text(text)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.18), in: Capsule())
                }
            }
        }
    }

    private var items: [(String, Color)] {
        var r: [(String, Color)] = []
        if status.upsFault { r.append(("Falla de la UPS", .dangerRed)) }
        if status.batteryLow { r.append(("Batería baja", .dangerRed)) }
        if status.avrActive { r.append(("AVR activo", .blue)) }
        if status.testInProgress { r.append(("Test en curso", .blue)) }
        if status.shutdownActive { r.append(("Apagado UPS programado", .warningAmber)) }
        return r
    }
}

struct WarningBanner: View {
    @Environment(UPSMonitor.self) private var monitor

    var body: some View {
        if case .warning(_, let deadline, let reason) = monitor.phase {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "power.circle.fill")
                        .foregroundStyle(Color.dangerRed)
                    Text("Apagando en \(deadline, style: .timer)")
                        .monospacedDigit()
                }
                .font(.headline)
                Text(reason.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    if monitor.canPostpone {
                        Button("Posponer 5 min") { monitor.postpone() }
                            .buttonStyle(.solid(.secondary))
                    }
                    Spacer()
                    Button("Apagar ahora", role: .destructive) { monitor.shutdownNow() }
                        .buttonStyle(.solid())
                }
            }
            .padding(12)
            .background(Color.dangerRed.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dangerRed.opacity(0.55)))
        }
    }
}
