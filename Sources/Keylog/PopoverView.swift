import AppKit
import Charts
import KeylogCore
import SwiftUI

enum HistoryMetric: String, CaseIterable, Identifiable {
    case keys, clicks, mouse, scroll
    var id: Self { self }
    var title: String {
        switch self {
        case .keys: "Keys"
        case .clicks: "Clicks"
        case .mouse: "Mouse"
        case .scroll: "Scroll"
        }
    }

    func value(_ counts: Counts) -> Double {
        switch self {
        case .keys: Double(counts.keys)
        case .clicks: Double(counts.clicks)
        case .mouse: counts.mouseMM / 1000
        case .scroll: counts.scrollMM / 1000
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .keys, .clicks: Format.compact(Int(value.rounded()))
        case .mouse, .scroll: Format.distance(mm: value * 1000)
        }
    }
}

/// The frosted-glass panel under the menu bar icon.
struct PopoverView: View {
    let model: AppModel
    /// Live values, fed only while the panel is showing.
    @ObservedObject var feed: PanelFeed
    let actions: AppActions
    @State private var days = 7
    @AppStorage("historyLine") private var lineChart = false
    @State private var metric = HistoryMetric.keys
    @State private var history: PeriodStats?
    @State private var firstDay: Date?
    /// Keys per hour today as stored when the panel opened, plus today's total then,
    /// so the current hour can grow live from the running total.
    @State private var hourly: [Int] = []
    @State private var hourlyBase = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !feed.isCounting { permissionBanner }
            hero
            tiles
            topKeys
            historyCard
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear(perform: load)
        .onChange(of: days) { loadHistory() }
        .onChange(of: feed.openCount) { load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Today").font(.title3.weight(.semibold))
            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.isPaused.toggle()
            } label: {
                Label(feed.isPaused ? "Resume" : "Pause", systemImage: feed.isPaused ? "play.fill" : "pause.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(IconButtonStyle())
            .help(feed.isPaused ? "Resume counting" : "Pause counting")
        }
        .padding(.horizontal, 2)
    }

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Not counting yet").font(.callout.weight(.medium))
            Spacer()
            Button("Allow…", action: actions.allowAccess)
                .controlSize(.small)
        }
        .padding(10)
        .glassCard(tint: .orange)
    }

    // MARK: Hero

    private var hero: some View {
        let today = feed.today
        let bars = liveHourly
        let hour = Calendar.current.component(.hour, from: Date())
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.count(today.keys))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("keys")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if feed.isPaused {
                    Text("Paused")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                } else if bars.indices.contains(hour) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Format.count(bars[hour]))
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                        Text("this hour")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            GroupBar(counts: today, height: 6)
            HStack(alignment: .top, spacing: 4) {
                ForEach(KeyGroup.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Circle().fill(Theme.color(group)).frame(width: 6, height: 6)
                            Text(Theme.name(group))
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        Text(Format.count(today[group]))
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                        Text(Format.percent(today[group], of: today.keys))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider().opacity(0.5)
            HourlyBars(values: bars, currentHour: hour)
                .frame(height: 38)
        }
        .padding(14)
        .glassCard()
    }

    private var liveHourly: [Int] {
        guard hourly.count == 24 else { return Array(repeating: 0, count: 24) }
        var bars = hourly
        let hour = Calendar.current.component(.hour, from: Date())
        bars[hour] += max(0, feed.today.keys - hourlyBase)
        return bars
    }

    // MARK: Tiles

    private var tiles: some View {
        let today = feed.today
        let clicks = "Left \(Format.compact(today.clicksLeft)) · Right \(Format.compact(today.clicksRight))"
        let typing = today.activeMinutes > 0
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                StatTile(icon: "cursorarrow.click.2", tint: .blue, title: "Clicks",
                         value: Format.count(today.clicks),
                         caption: today.peakCPS > 0 ? clicks + " · peak \(today.peakCPS)/s" : clicks)
                StatTile(icon: "arrow.up.and.down.and.arrow.left.and.right", tint: .green, title: "Mouse",
                         value: Format.distance(mm: today.mouseMM), caption: "pointer travel")
            }
            GridRow {
                StatTile(icon: "scroll", tint: .orange, title: "Scroll",
                         value: Format.distance(mm: today.scrollMM), caption: "wheel and trackpad")
                StatTile(icon: "speedometer", tint: .purple, title: "Speed",
                         value: feed.liveKPM > 0 ? "\(feed.liveKPM)/min" : typing ? "\(Int(today.keysPerActiveMinute.rounded()))/min" : "–",
                         caption: typing ? "avg \(Int(today.keysPerActiveMinute.rounded()))/min · ≈ \(Int((today.keysPerActiveMinute / 5).rounded())) wpm" : "keys per minute typing",
                         badge: feed.liveKPM > 0 ? "live" : nil)
            }
        }
    }

    // MARK: Top keys

    private var topKeys: some View {
        let top = Array(feed.todayKeys.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(5))
        let maxCount = top.first?.value ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Top keys").font(.headline)
                Spacer()
                Button {
                    actions.openDashboard(.keyboard)
                } label: {
                    HStack(spacing: 3) {
                        Text("Heatmap")
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                }
                .buttonStyle(LinkButtonStyle())
            }
            if top.isEmpty {
                Text("No keys yet today.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 10) {
                    ForEach(top, id: \.key) { code, count in
                        HeatKeyCap(code: code, count: count, level: maxCount > 0 ? Double(count) / Double(maxCount) : 0)
                    }
                }
            }
        }
        .padding(14)
        .glassCard()
    }

    // MARK: History

    private var historyCard: some View {
        let points = historyPoints
        let recorded = points.filter { $0.hasData }
        let total = recorded.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(days == 7 ? "Last 7 days" : "Last 30 days").font(.headline)
                Spacer()
                Picker("Show", selection: $metric) {
                    ForEach(HistoryMetric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                Picker("Range", selection: $days) {
                    Text("7D").tag(7)
                    Text("30D").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                Button {
                    lineChart.toggle()
                } label: {
                    Image(systemName: lineChart ? "chart.bar.fill" : "chart.xyaxis.line")
                }
                .buttonStyle(IconButtonStyle())
                .help(lineChart ? "Show as bars" : "Show as a line")
            }
            Chart(points, id: \.day) { point in
                if lineChart {
                    if point.hasData {
                        AreaMark(x: .value("Day", point.day, unit: .day), y: .value(metric.title, point.value))
                            .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Day", point.day, unit: .day), y: .value(metric.title, point.value))
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        PointMark(x: .value("Day", point.day, unit: .day), y: .value(metric.title, point.value))
                            .foregroundStyle(Color.accentColor)
                            .symbolSize(point.isToday ? 40 : 16)
                    }
                } else if point.hasData {
                    BarMark(x: .value("Day", point.day, unit: .day), y: .value(metric.title, point.value))
                        .foregroundStyle(point.isToday ? Color.accentColor.gradient : Color.accentColor.opacity(0.5).gradient)
                        .cornerRadius(3)
                } else {
                    // Before Keylog was counting: a faint stub, not a zero.
                    BarMark(x: .value("Day", point.day, unit: .day), yStart: .value("", 0), yEnd: .value("", max(total, 1) * 0.004))
                        .foregroundStyle(Color.primary.opacity(0.15))
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: days == 7 ? 1 : 7)) { _ in
                    AxisValueLabel(format: days == 7 ? .dateTime.weekday(.narrow) : .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(metric.format(v)) }
                    }
                }
            }
            .frame(height: 78)
            Text(recorded.isEmpty ? "Nothing counted yet."
                 : "Total \(metric.format(total)) · ≈ \(metric.format(total / Double(recorded.count))) a day"
                 + (recorded.count < points.count ? " · counting for \(recorded.count) \(recorded.count == 1 ? "day" : "days")" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .glassCard()
    }

    private struct HistoryPoint {
        let day: Date
        let value: Double
        let isToday: Bool
        let hasData: Bool
    }

    private var historyPoints: [HistoryPoint] {
        guard let history else { return [] }
        let todayKey = model.clock.day(for: Date())
        let firstRecorded = firstDay.map { Calendar.current.startOfDay(for: $0) } ?? Calendar.current.startOfDay(for: Date())
        return zip(history.slots, history.slotCounts).map { slot, counts in
            let isToday = slot.key == todayKey
            return HistoryPoint(day: slot.start, value: metric.value(isToday ? feed.today : counts),
                                isToday: isToday, hasData: slot.start >= firstRecorded)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                actions.openDashboard(.overview)
            } label: {
                Label("Open Dashboard", systemImage: "chart.bar.xaxis")
            }
            .modifier(ProminentButton())
            .controlSize(.large)
            Spacer()
            Group {
                Button { actions.openDashboard(.apps) } label: { Image(systemName: "square.grid.2x2") }
                    .help("Apps")
                Button { model.widget.isVisible.toggle() } label: {
                    Image(systemName: feed.widgetVisible ? "pip.fill" : "pip")
                }
                .help(feed.widgetVisible ? "Hide floating widget" : "Show floating widget")
                Button(action: actions.openSettings) { Image(systemName: "gearshape") }
                    .help("Settings")
                Button(action: actions.quit) { Image(systemName: "power") }
                    .help("Quit Keylog")
            }
            .buttonStyle(IconButtonStyle())
        }
        .padding(.top, 2)
    }

    // MARK: Loading

    private func load() {
        firstDay = model.firstDay
        let today = model.stats(for: model.period(.day))
        var bars = Array(repeating: 0, count: 24)
        for (slot, counts) in zip(today.slots, today.slotCounts) {
            if let hour = Int(slot.key), bars.indices.contains(hour) { bars[hour] += counts.keys }
        }
        hourly = bars
        hourlyBase = feed.today.keys
        loadHistory()
    }

    private func loadHistory() {
        history = model.stats(for: model.recentDays(days))
    }
}

// MARK: - Pieces

extension View {
    /// A translucent module on the frosted panel, like Control Center's.
    func glassCard(tint: Color? = nil, radius: CGFloat = 12) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(tint.map { AnyShapeStyle($0.opacity(0.14)) } ?? AnyShapeStyle(Color.glassModule)))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

extension Color {
    /// White at low strength on dark glass, stronger on light glass.
    static let glassModule = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.07)
            : NSColor.white.withAlphaComponent(0.55)
    })
}

/// Today's keys per hour; the current hour is highlighted, later hours are empty.
struct HourlyBars: View {
    let values: [Int]
    let currentHour: Int

    var body: some View {
        let peak = max(1, values.max() ?? 1)
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(values.indices, id: \.self) { hour in
                    let value = values[hour]
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(hour == currentHour ? AnyShapeStyle(Color.accentColor)
                              : hour < currentHour ? AnyShapeStyle(Color.accentColor.opacity(0.45))
                              : AnyShapeStyle(Color.primary.opacity(0.1)))
                        .frame(height: max(2, 26 * CGFloat(value) / CGFloat(peak)))
                        .frame(maxWidth: .infinity, maxHeight: 26, alignment: .bottom)
                        .help("\(hourName(hour)): \(Format.count(value)) keys")
                }
            }
            HStack {
                Text("12 AM")
                Spacer()
                Text("12 PM")
                Spacer()
                Text("11 PM")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
    }

    private func hourName(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

struct StatTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let caption: String
    /// A small live marker next to the title.
    var badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(tint.gradient, in: Circle())
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let badge {
                    HStack(spacing: 3) {
                        Circle().fill(.green).frame(width: 5, height: 5)
                        Text(badge)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                }
            }
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

/// A keycap filled with its heat colour, its count underneath.
struct HeatKeyCap: View {
    let code: UInt16
    let count: Int
    let level: Double
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Text(KeyNames.chip(code))
                .font(.system(size: KeyNames.chip(code).count > 2 ? 10.5 : 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Theme.heatLabel(level))
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.heat(level).gradient)
                        .shadow(color: .black.opacity(0.2), radius: 0.5, y: 1))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(hovering ? Color.primary.opacity(0.6) : Color.white.opacity(0.18), lineWidth: hovering ? 1.5 : 0.5))
            Text(Format.compact(count))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("\(KeyNames.full(code)): \(Format.count(count)) presses today")
    }
}

/// The five key groups as one stacked bar.
struct GroupBar: View {
    let counts: Counts
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: counts.keys > 0 ? 1.5 : 0) {
                if counts.keys == 0 {
                    Capsule().fill(.quaternary)
                } else {
                    ForEach(KeyGroup.allCases, id: \.self) { group in
                        let share = CGFloat(counts[group]) / CGFloat(counts.keys)
                        if share > 0 {
                            Rectangle()
                                .fill(Theme.color(group))
                                .frame(width: max(2, (geometry.size.width - 6) * share))
                        }
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

struct GroupLegend: View {
    let group: KeyGroup
    let counts: Counts
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.color(group)).frame(width: 7, height: 7)
            Text(Theme.name(group))
            Spacer(minLength: 4)
            Text(Format.count(counts[group]))
                .monospacedDigit()
            Text(Format.percent(counts[group], of: counts.keys))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: compact ? 34 : 40, alignment: .trailing)
        }
        .font(compact ? .system(size: 12) : .callout)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
    }
}

/// A key drawn as a small keycap.
struct KeyChip: View {
    let code: UInt16

    var body: some View {
        Text(KeyNames.chip(code))
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// Borderless icon button with hover and pressed backgrounds.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .padding(.horizontal, 7)
                .frame(minWidth: 30, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(configuration.isPressed ? AnyShapeStyle(Color.primary.opacity(0.16))
                              : hovering ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(Color.clear)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Quiet text link that underlines on hover.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LinkBody(configuration: configuration)
    }

    private struct LinkBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.caption.weight(.medium))
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
