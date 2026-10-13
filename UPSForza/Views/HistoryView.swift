import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers
import UPSKit

/// Ventana con el historial de la red eléctrica: cortes de luz y activaciones del AVR.
struct HistoryView: View {
    @Environment(UPSMonitor.self) private var monitor

    enum Period: Int, CaseIterable, Identifiable {
        case week = 7, month = 30, quarter = 90
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .week: "7 días"
            case .month: "30 días"
            case .quarter: "90 días"
            }
        }
        /// A 90 días las barras diarias quedan demasiado finas: se agrupan por semana.
        var bin: Calendar.Component { self == .quarter ? .weekOfYear : .day }
        var binName: String { self == .quarter ? "semana" : "día" }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case episodes = "Episodios"
        case days = "Por día"
        var id: String { rawValue }
    }

    @State private var period: Period = .week
    @State private var tab: Tab = .episodes
    @State private var snapshot = HistorySnapshot()
    @State private var loadError: String?

    private var days: [DaySummary] { HistorySummary.daily(snapshot, days: period.rawValue) }

    /// Días agrupados según el período (por día, o por semana a 90 días).
    private var bins: [ChartBin] {
        let cal = Calendar.current
        var result: [Date: ChartBin] = [:]
        for d in days {
            let start = period.bin == .day ? d.date : (cal.dateInterval(of: .weekOfYear, for: d.date)?.start ?? d.date)
            var bin = result[start] ?? ChartBin(start: start)
            bin.outageSeconds += d.outageSeconds
            bin.avrCount += d.avrCount
            result[start] = bin
        }
        return result.values.sorted { $0.start < $1.start }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.dangerRed)
                }
                SummaryTiles(days: days)
                HStack(alignment: .top, spacing: 16) {
                    BinnedBarChart(
                        title: "Tiempo sin luz por \(period.binName) (min)",
                        color: .chartOutage,
                        bins: bins,
                        period: period,
                        value: { $0.outageSeconds / 60 },
                        integerAxis: false,
                        format: { $0 > 0 ? TimeInterval($0 * 60).durationText : "Sin cortes" }
                    )
                    BinnedBarChart(
                        title: "Activaciones del AVR por \(period.binName)",
                        color: .chartAVR,
                        bins: bins,
                        period: period,
                        value: { Double($0.avrCount) },
                        integerAxis: true,
                        format: { "\(Int($0)) \(Int($0) == 1 ? "activación" : "activaciones")" }
                    )
                }
                Picker("Vista", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)

                switch tab {
                case .episodes: EpisodeList(snapshot: snapshot)
                case .days: DayTable(days: days)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 760, minHeight: 640)
        .task(id: "\(period.rawValue)-\(monitor.historyRevision)") {
            // Recarga al abrir, al cambiar el período y cada 30 s.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Historial de la red")
                    .font(.title2.weight(.semibold))
                Text("Cortes de luz y correcciones de voltaje (AVR) de la UPS")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Período", selection: $period) {
                ForEach(Period.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            ClearHistoryButton(label: "Borrar…", compact: true)
            Menu {
                Button("Episodios…") { export(.episodes) }
                Button("Resumen por día…") { export(.days) }
            } label: {
                Label("Exportar CSV", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
        }
    }

    private func load() async {
        do {
            snapshot = try await monitor.loadHistory(days: period.rawValue)
            loadError = nil
        } catch {
            loadError = "No se pudo cargar el historial: \(error)"
        }
    }

    private func export(_ kind: Tab) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let stamp = HistoryCSV.fileStamp()
        panel.nameFieldStringValue = kind == .episodes ? "ups-forza-episodios-\(stamp).csv" : "ups-forza-dias-\(stamp).csv"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = kind == .episodes ? HistoryCSV.episodes(snapshot) : HistoryCSV.days(days)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            loadError = "No se pudo exportar: \(error.localizedDescription)"
        }
    }
}

// MARK: - Resumen

private struct SummaryTiles: View {
    let days: [DaySummary]

    var body: some View {
        let outages = days.reduce(0) { $0 + $1.outages }
        let outageTime = days.reduce(0) { $0 + $1.outageSeconds }
        let avr = days.reduce(0) { $0 + $1.avrCount }
        let avrTime = days.reduce(0) { $0 + $1.avrSeconds }
        let mins = days.compactMap(\.inputMin)
        let maxs = days.compactMap(\.inputMax)
        let range = mins.isEmpty ? "—" : String(format: "%.0f–%.0f V", mins.min()!, maxs.max()!)

        Grid(horizontalSpacing: 12) {
            GridRow {
                StatTile(title: "Cortes de luz", value: "\(outages)", symbol: "bolt.slash.fill", tint: .chartOutage)
                StatTile(title: "Tiempo sin luz", value: outageTime > 0 ? outageTime.durationText : "0 s",
                         symbol: "clock", tint: .chartOutage)
                StatTile(title: "Activaciones AVR", value: "\(avr)", symbol: "waveform.path.ecg", tint: .chartAVR)
                StatTile(title: "Tiempo con AVR", value: avrTime > 0 ? avrTime.durationText : "0 s",
                         symbol: "clock", tint: .chartAVR)
                StatTile(title: "Entrada de la red", value: range, symbol: "arrow.down.to.line", tint: .secondary)
            }
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Gráfico

struct ChartBin: Identifiable {
    var id: Date { start }
    let start: Date
    var outageSeconds: TimeInterval = 0
    var avrCount = 0
}

/// Barras de una sola magnitud por día o por semana (sin leyenda: el título la nombra).
/// Al pasar el mouse muestra el valor de la barra.
private struct BinnedBarChart: View {
    let title: String
    let color: Color
    let bins: [ChartBin]
    let period: HistoryView.Period
    let value: (ChartBin) -> Double
    /// Conteos: marcas del eje Y solo en enteros.
    let integerAxis: Bool
    let format: (Double) -> String

    @State private var selected: Date?

    private var selectedBin: ChartBin? {
        guard let selected else { return nil }
        let cal = Calendar.current
        return bins.first { cal.isDate($0.start, equalTo: selected, toGranularity: period.bin) }
    }

    private var maxValue: Double { bins.map(value).max() ?? 0 }

    /// Paso del eje Y: para conteos, entero y con a lo sumo ~4 marcas.
    private var yStride: Double? {
        guard integerAxis else { return nil }
        return max(1, (maxValue / 4).rounded(.up))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Chart {
                ForEach(bins) { bin in
                    BarMark(
                        x: .value("Fecha", bin.start, unit: period.bin),
                        y: .value("Valor", value(bin))
                    )
                    .foregroundStyle(color)
                    .cornerRadius(4)
                    .opacity(selectedBin == nil || selectedBin?.start == bin.start ? 1 : 0.45)
                }
                if let bin = selectedBin {
                    RuleMark(x: .value("Fecha", bin.start, unit: period.bin))
                        .foregroundStyle(.secondary.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .zIndex(-1)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(bin)
                        }
                }
            }
            .chartXSelection(value: $selected)
            .chartXAxis { xAxis }
            .chartYScale(domain: 0...max(maxValue, integerAxis ? 1 : 5))
            .chartYAxis {
                if let yStride {
                    AxisMarks(position: .leading, values: .stride(by: yStride)) { _ in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel()
                    }
                } else {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel()
                    }
                }
            }
            .frame(height: 170)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Etiquetas del eje X: cada día (7 días), cada semana (30 días) o cada mes (90 días).
    @AxisContentBuilder
    private var xAxis: some AxisContent {
        switch period {
        case .week:
            AxisMarks(values: .stride(by: .day)) {
                AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: true)
            }
        case .month:
            AxisMarks(values: .stride(by: .weekOfYear)) {
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        case .quarter:
            AxisMarks(values: .stride(by: .month)) {
                AxisValueLabel(format: .dateTime.month(.abbreviated))
            }
        }
    }

    private func tooltip(_ bin: ChartBin) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if period.bin == .day {
                    Text(bin.start, format: .dateTime.weekday(.wide).day().month())
                } else {
                    Text("Semana del \(bin.start.formatted(.dateTime.day().month()))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(format(value(bin)))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }
}

// MARK: - Episodios

private struct Episode: Identifiable {
    enum Kind { case outage, avr }
    let id: UUID
    let kind: Kind
    let start: Date
    let end: Date?
    let inProgress: Bool
    let detail: String
    let imported: Bool

    var duration: String {
        if inProgress { return "en curso" }
        guard let end else { return "sin cierre" }
        return end.timeIntervalSince(start).durationText
    }
}

private struct EpisodeList: View {
    let snapshot: HistorySnapshot

    private var episodes: [Episode] {
        let outages = snapshot.outages.map { o in
            var parts: [String] = []
            if let v = o.minBatteryVoltage, let p = o.minBatteryPercent {
                parts.append(String(format: "Batería mín. %.2f V (%d %%)", v, p))
            }
            if let l = o.maxLoadPercent { parts.append("Consumo máx. \(l) %") }
            if let r = o.shutdownReason { parts.append("Apagó la Mac: \(r)") }
            return Episode(id: o.id, kind: .outage, start: o.start, end: o.end,
                           inProgress: o.id == snapshot.currentOutageID,
                           detail: parts.joined(separator: " · "), imported: o.imported)
        }
        let avr = snapshot.avr.map { a in
            let mode = switch a.mode {
            case .buck: "Reducción"
            case .boost: "Elevación"
            case .unknown: "Corrección"
            }
            let detail = String(format: "%@ · entrada %.0f–%.0f V → salida %.0f–%.0f V",
                                 mode, a.inputMin, a.inputMax, a.outputMin, a.outputMax)
            return Episode(id: a.id, kind: .avr, start: a.start, end: a.end,
                           inProgress: a.id == snapshot.currentAVRID, detail: detail, imported: a.imported)
        }
        return (outages + avr).sorted { $0.start > $1.start }
    }

    var body: some View {
        let items = episodes
        if items.isEmpty {
            ContentUnavailableView("Sin episodios", systemImage: "checkmark.seal",
                                   description: Text("No hubo cortes de luz ni activaciones del AVR en este período."))
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                ForEach(items) { e in
                    EpisodeRow(episode: e)
                    if e.id != items.last?.id { Divider() }
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private struct EpisodeRow: View {
    let episode: Episode

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: episode.kind == .outage ? "bolt.slash.fill" : "waveform.path.ecg")
                .foregroundStyle(episode.kind == .outage ? Color.chartOutage : Color.chartAVR)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(episode.kind == .outage ? "Corte de luz" : "AVR activo")
                        .font(.callout.weight(.semibold))
                    if episode.imported {
                        Text("del registro")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .help("Reconstruido a partir del registro de texto: los datos son aproximados.")
                    }
                }
                if !episode.detail.isEmpty {
                    Text(episode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(episode.start, format: .dateTime.day().month().hour().minute())
                    .font(.callout)
                    .monospacedDigit()
                Text(episode.duration)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Por día

private struct DayTable: View {
    let days: [DaySummary]

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Text("Día").gridColumnAlignment(.leading)
                Text("Cortes")
                Text("Sin luz")
                Text("AVR")
                Text("Con AVR")
                Text("Entrada mín.")
                Text("Prom.")
                Text("Máx.")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(days) { d in
                GridRow {
                    Text(d.date, format: .dateTime.weekday(.abbreviated).day().month())
                    Text("\(d.outages)")
                    Text(d.outageSeconds > 0 ? d.outageSeconds.durationText : "—")
                    Text("\(d.avrCount)")
                    Text(d.avrSeconds > 0 ? d.avrSeconds.durationText : "—")
                    Text(d.inputMin.map { String(format: "%.1f V", $0) } ?? "—")
                    Text(d.inputAverage.map { String(format: "%.1f V", $0) } ?? "—")
                    Text(d.inputMax.map { String(format: "%.1f V", $0) } ?? "—")
                }
                .font(.callout)
                .monospacedDigit()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - CSV

enum HistoryCSV {
    private static func stamp(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    static func fileStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: .now)
    }

    private static func num(_ v: Double?, _ digits: Int = 1) -> String {
        v.map { String(format: "%.\(digits)f", $0) } ?? ""
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func episodes(_ snap: HistorySnapshot) -> String {
        var rows = ["tipo,inicio,fin,duracion_s,bateria_min_v,bateria_min_pct,consumo_max_pct,apagado,avr_modo,entrada_min_v,entrada_max_v,salida_min_v,salida_max_v,importado"]
        for o in snap.outages.sorted(by: { $0.start < $1.start }) {
            rows.append([
                "corte", stamp(o.start), stamp(o.end),
                o.end.map { String(Int($0.timeIntervalSince(o.start))) } ?? "",
                num(o.minBatteryVoltage, 2), o.minBatteryPercent.map(String.init) ?? "",
                o.maxLoadPercent.map(String.init) ?? "",
                quoted(o.shutdownReason?.description ?? ""), "", "", "", "", "",
                o.imported ? "si" : "no",
            ].joined(separator: ","))
        }
        for a in snap.avr.sorted(by: { $0.start < $1.start }) {
            rows.append([
                "avr", stamp(a.start), stamp(a.end),
                a.end.map { String(Int($0.timeIntervalSince(a.start))) } ?? "",
                "", "", "", "", a.mode.rawValue,
                num(a.inputMin), num(a.inputMax), num(a.outputMin), num(a.outputMax),
                a.imported ? "si" : "no",
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static func days(_ days: [DaySummary]) -> String {
        var rows = ["dia,cortes,sin_luz_s,avr,con_avr_s,entrada_min_v,entrada_prom_v,entrada_max_v"]
        for d in days.sorted(by: { $0.day < $1.day }) {
            rows.append([
                d.day, String(d.outages), String(Int(d.outageSeconds)), String(d.avrCount), String(Int(d.avrSeconds)),
                num(d.inputMin), num(d.inputAverage), num(d.inputMax),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}
