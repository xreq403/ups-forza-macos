import Charts
import SwiftUI
import UPSKit

/// Panel en vivo: valores actuales y gráficos de la última hora, 6 h o 24 h.
/// Un gráfico por magnitud (nunca dos escalas en un eje). Los cortes se sombrean.
struct DashboardView: View {
    @Environment(UPSMonitor.self) private var monitor

    @State private var range: SeriesRange = .hour1
    @State private var points: [SeriesPoint] = []
    @State private var loadError: String?
    /// Momento bajo el mouse, compartido por los tres gráficos.
    @State private var selected: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.dangerRed)
                }
                LiveTiles()
                if points.isEmpty {
                    ContentUnavailableView("Sin datos todavía", systemImage: "chart.xyaxis.line",
                                           description: Text("Los gráficos se llenan a medida que llegan lecturas de la UPS."))
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ChartCard(title: "Voltaje de la red") {
                        VoltageChart(points: points, range: range, selected: $selected)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        ChartCard(title: "Batería (V)") {
                            BatteryChart(points: points, range: range, selected: $selected)
                        }
                        ChartCard(title: "Consumo estimado (W)") {
                            LoadChart(points: points, range: range, selected: $selected)
                        }
                    }
                }
            }
            .padding(24)
        }
        .task(id: range) {
            // Última hora: cada 5 s (como las lecturas). Rangos largos: cada minuto.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(range == .hour1 ? 5 : 60))
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Panel en vivo")
                    .font(.title2.weight(.semibold))
                Text(range == .hour1 ? "Una lectura cada 5 s" : "Promedios por \(range == .hours6 ? "minuto" : "5 minutos")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Rango", selection: $range) {
                Text("1 h").tag(SeriesRange.hour1)
                Text("6 h").tag(SeriesRange.hours6)
                Text("24 h").tag(SeriesRange.hours24)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
        }
    }

    private func load() async {
        do {
            points = try await monitor.loadSeries(range)
            loadError = nil
        } catch {
            loadError = "No se pudieron cargar las lecturas: \(error)"
        }
    }
}

// MARK: - Valores actuales

private struct LiveTiles: View {
    @Environment(UPSMonitor.self) private var monitor

    var body: some View {
        if let s = monitor.status {
            Grid(horizontalSpacing: 12) {
                GridRow {
                    MetricTile(title: "Entrada", value: s.onBattery ? "Sin luz" : String(format: "%.1f V", s.inputVoltage),
                               symbol: "arrow.down.to.line")
                    MetricTile(title: "Salida", value: String(format: "%.1f V", s.outputVoltage), symbol: "arrow.up.to.line")
                    MetricTile(title: "Batería", value: String(format: "%.2f V", s.batteryVoltage),
                               detail: "\(s.batteryPercent) %", symbol: "battery.100percent")
                    MetricTile(title: "Consumo", value: "\(s.loadPercent) %", detail: "~\(s.estimatedWatts) W",
                               symbol: "gauge.with.dots.needle.33percent")
                    MetricTile(title: "Frecuencia", value: String(format: "%.1f Hz", s.frequency), symbol: "waveform.path")
                }
            }
            .opacity(monitor.link == .connected ? 1 : 0.5)
        }
    }
}

// MARK: - Gráficos

private struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content.frame(height: 180)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Utilidades comunes a los tres gráficos.
private enum ChartSupport {
    /// Ancho de cada punto según el rango (para sombrear cortes y unir tramos).
    static func step(_ range: SeriesRange) -> TimeInterval {
        switch range {
        case .hour1: 5
        case .hours6: 60
        case .hours24: 300
        }
    }

    /// Tramos seguidos con la UPS en batería, para sombrearlos.
    static func outages(_ points: [SeriesPoint], range: SeriesRange) -> [(start: Date, end: Date)] {
        var result: [(Date, Date)] = []
        var start: Date?
        var last: Date?
        for p in points {
            if p.onBattery {
                if start == nil { start = p.time }
                last = p.time
            } else if let s = start, let l = last {
                result.append((s, l.addingTimeInterval(step(range))))
                start = nil
            }
        }
        if let s = start, let l = last { result.append((s, l.addingTimeInterval(step(range)))) }
        return result
    }

    static func nearest(_ points: [SeriesPoint], to date: Date?) -> SeriesPoint? {
        guard let date else { return nil }
        return points.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }

    static var timeFormat: Date.FormatStyle { .dateTime.hour().minute() }
}

private struct OutageShading: ChartContent {
    let points: [SeriesPoint]
    let range: SeriesRange

    var body: some ChartContent {
        ForEach(Array(ChartSupport.outages(points, range: range).enumerated()), id: \.offset) { _, o in
            RectangleMark(xStart: .value("Inicio", o.start), xEnd: .value("Fin", o.end))
                .foregroundStyle(Color.chartOutage.opacity(0.15))
        }
    }
}

/// Línea vertical y tooltip con todos los valores del momento elegido.
private struct HoverRule: ChartContent {
    let point: SeriesPoint?

    var body: some ChartContent {
        if let p = point {
            RuleMark(x: .value("Hora", p.time))
                .foregroundStyle(.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.time, format: .dateTime.hour().minute().second())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if p.onBattery {
                            Text("Sin luz").font(.caption.weight(.semibold))
                        }
                        Text(p.inputAvg.map { String(format: "Entrada %.1f V", $0) } ?? "Entrada —")
                        Text(String(format: "Salida %.1f V", p.outputAvg))
                        Text(String(format: "Batería %.2f V", p.batteryMin))
                        Text(String(format: "Consumo ~%.0f W", p.watts))
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }
        }
    }
}

private struct VoltageChart: View {
    let points: [SeriesPoint]
    let range: SeriesRange
    @Binding var selected: Date?

    /// La entrada se corta durante los cortes: cada tramo con luz es una línea aparte.
    private var inputSegments: [(segment: Int, point: SeriesPoint)] {
        var seg = 0
        var result: [(Int, SeriesPoint)] = []
        for p in points {
            if p.inputAvg == nil { seg += 1; continue }
            result.append((seg, p))
        }
        return result
    }

    var body: some View {
        Chart {
            OutageShading(points: points, range: range)
            ForEach(inputSegments, id: \.point.time) { item in
                LineMark(x: .value("Hora", item.point.time), y: .value("V", item.point.inputAvg ?? 0),
                         series: .value("Tramo", "Entrada \(item.segment)"))
                    .foregroundStyle(by: .value("Serie", "Entrada"))
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            ForEach(points) { p in
                LineMark(x: .value("Hora", p.time), y: .value("V", p.outputAvg), series: .value("Tramo", "Salida"))
                    .foregroundStyle(by: .value("Serie", "Salida"))
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            HoverRule(point: ChartSupport.nearest(points, to: selected))
        }
        .chartForegroundStyleScale(["Entrada": Color.chartInput, "Salida": Color.chartOutput])
        .chartLegend(position: .top, alignment: .leading)
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis { AxisMarks { AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel(format: ChartSupport.timeFormat) } }
        .chartYAxis { AxisMarks(position: .leading) { AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
        .chartXSelection(value: $selected)
    }
}

private struct BatteryChart: View {
    let points: [SeriesPoint]
    let range: SeriesRange
    @Binding var selected: Date?

    var body: some View {
        Chart {
            OutageShading(points: points, range: range)
            ForEach(points) { p in
                LineMark(x: .value("Hora", p.time), y: .value("V", p.batteryMin))
                    .foregroundStyle(Color.batteryGreen)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            HoverRule(point: ChartSupport.nearest(points, to: selected))
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel(format: ChartSupport.timeFormat) } }
        .chartYAxis { AxisMarks(position: .leading) { AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
        .chartXSelection(value: $selected)
    }
}

private struct LoadChart: View {
    let points: [SeriesPoint]
    let range: SeriesRange
    @Binding var selected: Date?

    var body: some View {
        Chart {
            OutageShading(points: points, range: range)
            ForEach(points) { p in
                AreaMark(x: .value("Hora", p.time), y: .value("W", p.watts))
                    .foregroundStyle(Color.chartInput.opacity(0.15))
                LineMark(x: .value("Hora", p.time), y: .value("W", p.watts))
                    .foregroundStyle(Color.chartInput)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            HoverRule(point: ChartSupport.nearest(points, to: selected))
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel(format: ChartSupport.timeFormat) } }
        .chartYAxis { AxisMarks(position: .leading) { AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
        .chartXSelection(value: $selected)
    }
}
