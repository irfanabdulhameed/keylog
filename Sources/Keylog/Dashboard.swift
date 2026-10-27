import AppKit
import Charts
import KeylogCore
import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview, keyboard, apps, mouse, calendar
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .keyboard: "Keyboard"
        case .apps: "Apps"
        case .mouse: "Mouse"
        case .calendar: "Calendar"
        }
    }
    var icon: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .keyboard: "keyboard"
        case .apps: "square.grid.2x2"
        case .mouse: "computermouse"
        case .calendar: "calendar"
        }
    }
}

extension PeriodKind: Identifiable {
    public var id: Self { self }
    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .all: "All time"
        }
    }
}

final class DashboardState: ObservableObject {
    @Published var section = DashboardSection.overview
    @Published var kind = PeriodKind.day
    @Published var anchor = Date()
    /// App the keyboard heatmap is filtered to; nil is every app.
    @Published var app: String?
    @Published var year = Calendar.current.component(.year, from: Date())
    /// Bumped every 15 seconds while the window is open, so current periods stay live.
    @Published var tick = 0
    var openSettings: () -> Void = {}
    var checkForUpdates: () -> Void = {}
}

/// Owns the dashboard window. Closing it frees everything it held.
final class DashboardController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let state = DashboardState()
    private var window: NSWindow?
    private var timer: Timer?

    init(model: AppModel, openSettings: @escaping () -> Void, checkForUpdates: @escaping () -> Void) {
        self.model = model
        state.openSettings = openSettings
        state.checkForUpdates = checkForUpdates
    }

    func show(_ section: DashboardSection) {
        state.section = section
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Keylog"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.toolbar = NSToolbar(identifier: "dashboard")
            window.titleVisibility = .hidden
            let host = NSHostingController(rootView: DashboardView(model: model, state: state))
            host.sizingOptions = []
            window.contentViewController = host
            window.minSize = NSSize(width: 900, height: 620)
            window.isReleasedWhenClosed = false
            window.delegate = self
            if !window.setFrameUsingName("KeylogDashboard") {
                window.setContentSize(NSSize(width: 1100, height: 760))
                window.center()
            }
            window.setFrameAutosaveName("KeylogDashboard")
            self.window = window
            let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.state.tick += 1 }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        // While it's open, Keylog is in the Dock and ⌘-Tab.
        MainActor.assumeIsolated { DockPresence.show(.dashboard) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { DockPresence.hide(.dashboard) }
        timer?.invalidate()
        timer = nil
        window?.contentViewController = nil
        window = nil
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: DashboardState

    var body: some View {
        let period = model.period(state.kind, containing: state.anchor)
        if Snapshot.isRendering {
            // The glass sidebar can't be captured offscreen; draw a look-alike.
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(DashboardSection.allCases) { section in
                        Label(section.title, systemImage: section.icon)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(state.section == section ? Color.primary.opacity(0.1) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    Spacer()
                }
                .padding(.top, 52)
                .padding(.horizontal, 10)
                .frame(width: 200)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(8)
                detail(period)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            splitView(period)
        }
    }

    private func detail(_ period: Period) -> some View {
        VStack(spacing: 0) {
            DashboardHeader(model: model, state: state, period: period)
            Divider()
            ScrollView {
                section(period)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func splitView(_ period: Period) -> some View {
        NavigationSplitView {
            List(selection: Binding(get: { state.section }, set: { if let section = $0 { state.section = section } })) {
                ForEach(DashboardSection.allCases) { section in
                    Label(section.title, systemImage: section.icon).tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom, spacing: 0) { AboutBlock(checkForUpdates: state.checkForUpdates) }
        } detail: {
            detail(period)
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    @ViewBuilder private func section(_ period: Period) -> some View {
        let reload = ReloadID(period: period, app: state.app, tick: state.tick, version: model.dataVersion, year: state.year)
        switch state.section {
        case .overview: OverviewSection(model: model, state: state, period: period, reload: reload)
        case .keyboard: KeyboardSection(model: model, state: state, period: period, reload: reload)
        case .apps: AppsSection(model: model, state: state, period: period, reload: reload)
        case .mouse: MouseSection(model: model, state: state, period: period, reload: reload)
        case .calendar: CalendarSection(model: model, state: state, reload: reload)
        }
    }
}

/// The icon, name, version and Check for Updates at the bottom of the sidebar.
private struct AboutBlock: View {
    let checkForUpdates: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Keylog").font(.system(size: 12, weight: .semibold))
                Text(AppVersion.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Check for Updates", action: checkForUpdates)
                    .controlSize(.small)
                    .help("Ask GitHub whether a newer Keylog is out")
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// "Version 1.0.0 (3)", or "Development build" for a bare binary.
enum AppVersion {
    static var text: String {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "Development build" }
        return "Version \(short)" + ((info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? "")
    }
}

/// Changes whenever a section must load its data again.
struct ReloadID: Equatable {
    let period: Period
    let app: String?
    let tick: Int
    let version: Int
    let year: Int
}

struct DashboardHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: DashboardState
    let period: Period

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.section.title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.section == .calendar {
                Button { state.year -= 1 } label: { Image(systemName: "chevron.left") }
                    .help("Previous year")
                Text(String(state.year))
                    .font(.headline)
                    .monospacedDigit()
                Button { state.year += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(state.year >= Calendar.current.component(.year, from: Date()))
                    .help("Next year")
            } else {
                Picker("Period", selection: $state.kind) {
                    ForEach(PeriodKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                ControlGroup {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(state.kind == .all)
                        .keyboardShortcut(.leftArrow, modifiers: .command)
                        .help("Previous \(state.kind.title.lowercased()) (⌘←)")
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(state.kind == .all || period.contains(Date()))
                        .keyboardShortcut(.rightArrow, modifiers: .command)
                        .help("Next \(state.kind.title.lowercased()) (⌘→)")
                }
                .fixedSize()
                Button("Today") { state.anchor = Date() }
                    .disabled(period.contains(Date()))
                    .keyboardShortcut("t", modifiers: .command)
            }
            Menu {
                Button("Daily Totals as CSV…") { Exporter.csv(model) }
                Button("Full Backup as JSON…") { Exporter.json(model) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background {
            // ⌘1–⌘5 switch the period.
            ForEach(Array(PeriodKind.allCases.enumerated()), id: \.offset) { index, kind in
                Button("") { state.kind = kind }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .hidden()
            }
        }
    }

    private var subtitle: String {
        if state.section == .calendar { return "Every day of \(state.year)" }
        return PeriodTitle.text(period, calendar: model.calendar)
    }

    private func step(_ steps: Int) {
        state.anchor = period.shifted(by: steps, calendar: model.calendar).start
    }
}

enum PeriodTitle {
    static func text(_ period: Period, calendar: Calendar) -> String {
        let isCurrent = period.contains(Date())
        switch period.kind {
        case .day:
            let text = period.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
            return isCurrent ? "Today, \(text)" : text
        case .week:
            let formatter = DateIntervalFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            formatter.calendar = calendar
            let text = formatter.string(from: period.start, to: period.end.addingTimeInterval(-1))
            return isCurrent ? "This week, \(text)" : text
        case .month:
            return period.start.formatted(.dateTime.month(.wide).year())
        case .year:
            return period.start.formatted(.dateTime.year())
        case .all:
            return "Since \(period.start.formatted(.dateTime.day().month(.wide).year()))"
        }
    }

    /// Label for one chart bar.
    static func slot(_ slot: ChartSlot, unit: Period.Unit) -> String {
        switch unit {
        case .hour:
            let end = slot.start.addingTimeInterval(3600)
            return "\(slot.start.formatted(.dateTime.hour())) – \(end.formatted(.dateTime.hour()))"
        case .day: return slot.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .month: return slot.start.formatted(.dateTime.month(.wide).year())
        }
    }

    /// Short label under the first or last bar: "9 AM", "Sep 22", "Mar 25".
    static func edge(_ slot: ChartSlot, unit: Period.Unit, count: Int) -> String {
        switch unit {
        case .hour: slot.start.formatted(.dateTime.hour())
        case .day: slot.start.formatted(.dateTime.month(.abbreviated).day())
        case .month: count > 12 ? slot.start.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
                                : slot.start.formatted(.dateTime.month(.abbreviated))
        }
    }
}

extension Period.Unit {
    var component: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .month: .month
        }
    }
}

// MARK: - Overview

struct OverviewSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: DashboardState
    let period: Period
    let reload: ReloadID
    @State private var stats: PeriodStats?
    /// "group", "total" or "line".
    @AppStorage("overviewChart") private var chartMode = "group"
    @State private var deletes = 0

    var body: some View {
        let stats = stats ?? PeriodStats(period: period)
        let total = stats.total
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.count(total.keys))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("keys")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                if period.kind != .day {
                    let days = period.kind == .all ? max(1, stats.dailyTotals.count) : period.dayCount(calendar: model.calendar)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("≈ \(Format.count(total.keys / max(1, days))) a day")
                        Text("\(stats.activeDays) active \(stats.activeDays == 1 ? "day" : "days")")
                    }
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }

            HStack(spacing: 12) {
                ForEach(KeyGroup.allCases, id: \.self) { group in
                    GroupTile(group: group, counts: total)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(chartTitle).font(.headline)
                        Spacer()
                        Picker("Chart", selection: $chartMode) {
                            Text("By group").tag("group")
                            Text("Total").tag("total")
                            Text("Line").tag("line")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if total.keys == 0 {
                        EmptyChart(message: period.contains(Date()) && period.kind == .day
                                   ? "Start typing. Today's count appears here."
                                   : "Nothing was counted in this period.")
                    } else {
                        ActivityChart(stats: stats, stacked: chartMode == "group", metric: .keys, line: chartMode == "line") { slot in
                            drill(into: slot)
                        }
                            .frame(height: 240)
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Share").font(.headline)
                        HStack(spacing: 20) {
                            Chart(KeyGroup.allCases, id: \.self) { group in
                                SectorMark(angle: .value("Keys", total[group]), innerRadius: .ratio(0.62), angularInset: 1.5)
                                    .foregroundStyle(Theme.color(group))
                                    .cornerRadius(3)
                            }
                            .frame(width: 140, height: 140)
                            .overlay {
                                if total.keys == 0 { Circle().strokeBorder(.quaternary, lineWidth: 22) }
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(KeyGroup.allCases, id: \.self) { group in
                                    GroupLegend(group: group, counts: total)
                                }
                            }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Typing speed").font(.headline)
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                            SpeedRow(title: "Fastest second", value: total.peakKPS > 0 ? "\(total.peakKPS) keys" : "–")
                            SpeedRow(title: "While typing", value: total.activeMinutes > 0 ? "\(Int(total.keysPerActiveMinute.rounded())) keys/min" : "–")
                            SpeedRow(title: "Estimated speed", value: total.activeMinutes > 0 ? "≈ \(Int((total.keysPerActiveMinute / 5).rounded())) wpm" : "–")
                            SpeedRow(title: "Time typing", value: Format.duration(minutes: total.activeMinutes))
                        }
                        Text("Speed counts only the minutes you were typing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            InsightsCard(stats: stats, deletes: deletes, calendar: model.calendar)
        }
        .task(id: reload) {
            self.stats = model.stats(for: period)
            let keys = model.keyCounts(for: period, app: nil)
            deletes = (keys[51] ?? 0) + (keys[117] ?? 0)
        }
    }

    private var chartTitle: String {
        switch period.unit {
        case .hour: "Keys per hour"
        case .day: "Keys per day"
        case .month: "Keys per month"
        }
    }

    private func drill(into slot: ChartSlot) {
        switch period.unit {
        case .hour: break
        case .day:
            state.kind = .day
            state.anchor = slot.start
        case .month:
            state.kind = .month
            state.anchor = slot.start
        }
    }
}

private struct SpeedRow: View {
    let title: String
    let value: String

    var body: some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
    }
}

struct GroupTile: View {
    let group: KeyGroup
    let counts: Counts

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.color(group)).frame(width: 10, height: 10)
                Text(Theme.name(group)).foregroundStyle(.secondary)
            }
            Text(Format.count(counts[group]))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(Format.percent(counts[group], of: counts.keys))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 0.5))
    }
}

struct EmptyChart: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

/// Bars over a period, with a hover tooltip; clicking a bar opens it.
struct ActivityChart: View {
    let stats: PeriodStats
    let stacked: Bool
    let metric: HistoryMetric
    /// A line through the totals instead of bars.
    var line = false
    var onSelect: (ChartSlot) -> Void = { _ in }
    /// Holds one bar in its hover state, for snapshot design checks.
    var pinnedHover: Int?
    @State private var hovered: Int?

    var body: some View {
        Group {
            if line { lineChart } else { bars }
        }
        .onChange(of: stats.period) { hovered = nil }
    }

    private var groupsShown: Bool { stacked && metric == .keys }

    private var bars: some View {
        let unit = stats.period.unit
        let columns = stats.slots.map { slot in
            let counts = stats.slotCounts[slot.index]
            let segments = groupsShown
                ? Theme.stackOrder.map { BarColumn.Segment(value: Double(counts[$0]), color: Theme.color($0)) }
                : [BarColumn.Segment(value: metric.value(counts), color: Theme.bar)]
            return BarColumn(id: slot.index, segments: segments,
                             label: "\(PeriodTitle.slot(slot, unit: unit)): \(metric.spoken(metric.value(counts)))")
        }
        let edges = stats.slots.first.flatMap { first in
            stats.slots.last.map { (PeriodTitle.edge(first, unit: unit, count: stats.slots.count),
                                    PeriodTitle.edge($0, unit: unit, count: stats.slots.count)) }
        }
        return BarChart(columns: columns, hovered: pinnedHover.map { .constant($0) } ?? $hovered, edgeLabels: edges,
                        onSelect: unit == .hour ? nil : { index in
                            if stats.slots.indices.contains(index) { onSelect(stats.slots[index]) }
                        }) { index in
            ChartTooltip(title: PeriodTitle.slot(stats.slots[index], unit: unit),
                         counts: stats.slotCounts[index], metric: metric, groups: groupsShown)
        }
    }

    private var lineChart: some View {
        let unit = stats.period.unit
        return Chart {
            ForEach(stats.slots) { slot in
                let counts = stats.slotCounts[slot.index]
                AreaMark(x: .value("Time", slot.start, unit: unit.component), y: .value(metric.title, metric.value(counts)))
                    .foregroundStyle(LinearGradient(colors: [Theme.bar.opacity(0.28), Theme.bar.opacity(0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Time", slot.start, unit: unit.component), y: .value(metric.title, metric.value(counts)))
                    .foregroundStyle(Theme.bar)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                if hovered == slot.index {
                    PointMark(x: .value("Time", slot.start, unit: unit.component), y: .value(metric.title, metric.value(counts)))
                        .foregroundStyle(Theme.bar)
                        .symbolSize(60)
                }
            }
        }
        .chartXAxis { xAxis(unit) }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(metric.format(v)) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            let date: Date? = proxy.value(atX: location.x - plot.minX)
                            hovered = date.flatMap { d in stats.slots.last { $0.start <= d }?.index }
                        case .ended:
                            hovered = nil
                        }
                    }
                    .onTapGesture {
                        if let hovered, stats.slots.indices.contains(hovered) { onSelect(stats.slots[hovered]) }
                    }
                if let hovered, stats.slots.indices.contains(hovered),
                   let x = proxy.position(forX: stats.slots[hovered].start) {
                    let width = plot.width / CGFloat(max(1, stats.slots.count))
                    ChartTooltip(title: PeriodTitle.slot(stats.slots[hovered], unit: unit),
                                 counts: stats.slotCounts[hovered], metric: metric, groups: metric == .keys)
                        .fixedSize()
                        .position(x: min(max(plot.minX + x + width / 2, 90), geometry.size.width - 90), y: 40)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @AxisContentBuilder
    private func xAxis(_ unit: Period.Unit) -> some AxisContent {
        switch unit {
        case .hour:
            AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour(), centered: false)
            }
        case .day:
            if stats.slots.count <= 7 {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated).day(), centered: true)
                }
            } else {
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                }
            }
        case .month:
            AxisMarks(values: .stride(by: .month, count: stats.slots.count > 14 ? 3 : 1)) { _ in
                AxisValueLabel(format: stats.slots.count > 14 ? .dateTime.month(.abbreviated).year(.twoDigits) : .dateTime.month(.abbreviated), centered: true)
            }
        }
    }
}

struct ChartTooltip: View {
    let title: String
    let counts: Counts
    let metric: HistoryMetric
    /// One row per key group, in stacking order.
    var groups = true

    var body: some View {
        if metric == .keys {
            BarTooltip(title: title, total: Format.count(counts.keys),
                       rows: groups ? Theme.stackOrder.filter { counts[$0] > 0 }.map {
                           BarTooltip.Row(name: Theme.name($0), color: Theme.color($0), value: Format.count(counts[$0]))
                       } : [])
        } else {
            BarTooltip(title: title, total: metric.format(metric.value(counts)))
        }
    }
}

// MARK: - Mouse

struct MouseSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: DashboardState
    let period: Period
    let reload: ReloadID
    @State private var stats: PeriodStats?
    @State private var metric = HistoryMetric.clicks
    @AppStorage("mouseChartLine") private var line = false

    var body: some View {
        let stats = stats ?? PeriodStats(period: period)
        let total = stats.total
        VStack(alignment: .leading, spacing: 16) {
            if !model.tracksMouse {
                Banner(text: "Mouse tracking is off. Clicks still count; travel and scrolling don't.",
                       action: "Open Settings", perform: state.openSettings)
            }
            HStack(spacing: 12) {
                BigTile(icon: "cursorarrow.click.2", title: "Clicks", value: Format.count(total.clicks),
                        detail: "Left \(Format.count(total.clicksLeft)) · Right \(Format.count(total.clicksRight)). Side and wheel buttons aren't counted.")
                BigTile(icon: "arrow.up.and.down.and.arrow.left.and.right", title: "Mouse travel",
                        value: Format.distance(mm: total.mouseMM), detail: "Measured from your screens' real size")
                BigTile(icon: "scroll", title: "Scroll", value: Format.distance(mm: total.scrollMM),
                        detail: "Finger and wheel scrolling, not momentum")
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Over time").font(.headline)
                        Spacer()
                        Picker("Show", selection: $metric) {
                            Text("Clicks").tag(HistoryMetric.clicks)
                            Text("Travel").tag(HistoryMetric.mouse)
                            Text("Scroll").tag(HistoryMetric.scroll)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Picker("Style", selection: $line) {
                            Image(systemName: "chart.bar.fill").tag(false)
                            Image(systemName: "chart.xyaxis.line").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .help("Bars or line")
                    }
                    if metric.value(total) == 0 {
                        EmptyChart(message: "Nothing was counted in this period.")
                    } else {
                        ActivityChart(stats: stats, stacked: false, metric: metric, line: line)
                            .frame(height: 220)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Left and right").font(.headline)
                    let sides = max(1, total.clicksLeft + total.clicksRight)
                    GeometryReader { geometry in
                        HStack(spacing: 2) {
                            Rectangle().fill(Color.accentColor)
                                .frame(width: geometry.size.width * CGFloat(total.clicksLeft) / CGFloat(sides))
                            Rectangle().fill(Color.orange)
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 10)
                    HStack {
                        Text("Left \(Format.percent(total.clicksLeft, of: sides))")
                        Spacer()
                        Text("Right \(Format.percent(total.clicksRight, of: sides))")
                    }
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
        }
        .task(id: reload) { self.stats = model.stats(for: period) }
    }
}

struct BigTile: View {
    let icon: String
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 0.5))
    }
}

struct Banner: View {
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
            Text(text)
            Spacer()
            Button(action, action: perform)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Insights

/// A few standout facts about the period: best day or hour, the busiest weekday,
/// how often Delete gets pressed, the fastest clicking, and fun distances.
struct InsightsCard: View {
    let stats: PeriodStats
    let deletes: Int
    let calendar: Calendar

    private struct Insight {
        let icon: String
        let title: String
        let value: String
        let detail: String
    }

    var body: some View {
        let items = insights
        if !items.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Insights").font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)],
                              alignment: .leading, spacing: 16) {
                        ForEach(items, id: \.title) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 28, height: 28)
                                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.caption).foregroundStyle(.secondary)
                                    Text(item.value).font(.body.weight(.semibold)).monospacedDigit()
                                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private var insights: [Insight] {
        let total = stats.total
        guard total.keys + total.clicks > 0 else { return [] }
        var list: [Insight] = []
        if stats.period.kind == .day {
            if let busiest = stats.slots.indices.max(by: { stats.slotCounts[$0].keys < stats.slotCounts[$1].keys }),
               stats.slotCounts[busiest].keys > 0 {
                list.append(Insight(icon: "clock", title: "Busiest hour",
                                    value: PeriodTitle.slot(stats.slots[busiest], unit: .hour),
                                    detail: "\(Format.count(stats.slotCounts[busiest].keys)) keys"))
            }
        } else if let best = stats.dailyTotals.max(by: { $0.value.keys < $1.value.keys }), best.value.keys > 0 {
            list.append(Insight(icon: "flame", title: "Best day", value: dayTitle(best.key),
                                detail: "\(Format.count(best.value.keys)) keys"))
        }
        if let weekday = busiestWeekday {
            list.append(weekday)
        }
        if total.keys > 0, deletes > 0 {
            list.append(Insight(icon: "delete.left", title: "Corrections", value: Format.percent(deletes, of: total.keys),
                                detail: "of your keys were Delete (\(Format.count(deletes)))"))
        }
        if total.peakCPS > 0 {
            list.append(Insight(icon: "cursorarrow.click.badge.clock", title: "Fastest clicking",
                                value: "\(total.peakCPS) clicks in a second", detail: "your quickest burst"))
        }
        if total.mouseMM > 0 {
            list.append(Insight(icon: "figure.run", title: "Mouse travel", value: Format.distance(mm: total.mouseMM),
                                detail: Self.travelComparison(mm: total.mouseMM)))
        }
        if total.scrollMM > 0 {
            list.append(Insight(icon: "arrow.up.and.down", title: "Scrolled", value: Format.distance(mm: total.scrollMM),
                                detail: Self.heightComparison(mm: total.scrollMM)))
        }
        return list
    }

    /// The weekday with the highest average, once there are at least 7 days to compare.
    private var busiestWeekday: Insight? {
        let days = stats.dailyTotals.filter { $0.value.keys > 0 }
        guard days.count >= 7 else { return nil }
        var sums: [Int: (keys: Int, days: Int)] = [:]
        for (day, counts) in days {
            guard let date = date(day) else { continue }
            let weekday = calendar.component(.weekday, from: date)
            sums[weekday, default: (0, 0)].keys += counts.keys
            sums[weekday, default: (0, 0)].days += 1
        }
        guard let best = sums.max(by: { $0.value.keys / $0.value.days < $1.value.keys / $1.value.days }) else { return nil }
        return Insight(icon: "calendar.badge.clock", title: "Most active day",
                       value: calendar.weekdaySymbols[best.key - 1] + "s",
                       detail: "≈ \(Format.count(best.value.keys / best.value.days)) keys on average")
    }

    private func date(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    private func dayTitle(_ day: String) -> String {
        date(day)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) ?? day
    }

    static func travelComparison(mm: Double) -> String {
        let metres = mm / 1000
        if metres >= 4219.5 { return String(format: "≈ %.1f marathons", metres / 42195) }
        if metres >= 105 { return String(format: "≈ %.1f football pitches", metres / 105) }
        return "≈ \(max(1, Int((metres / 105 * 100).rounded())))% of a football pitch"
    }

    static func heightComparison(mm: Double) -> String {
        let metres = mm / 1000
        if metres >= 884.8 { return String(format: "≈ %.1f times up Everest", metres / 8848) }
        if metres >= 33 { return String(format: "≈ %.1f Eiffel Towers", metres / 330) }
        return "≈ \(max(1, Int((metres / 3).rounded()))) storeys of a building"
    }
}
