import AppKit
import KeylogCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Keyboard

struct KeyboardSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: DashboardState
    let period: Period
    let reload: ReloadID
    @State private var counts: [UInt16: Int] = [:]
    @State private var apps: [(id: String, use: AppUse)] = []

    var body: some View {
        let total = counts.values.reduce(0, +)
        let maxCount = counts.values.max() ?? 0
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Picker("App", selection: $state.app) {
                    Text("All apps").tag(String?.none)
                    if !apps.isEmpty { Divider() }
                    ForEach(apps, id: \.id) { app in
                        Text(app.use.name).tag(String?.some(app.id))
                    }
                }
                .frame(maxWidth: 280)
                Spacer()
                Text("\(Format.count(total)) presses · \(counts.count) keys used")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Card {
                KeyboardHeatmap(counts: counts, total: total, maxCount: maxCount)
                    .overlay {
                        if total == 0 {
                            Text(state.app == nil ? "No keys pressed in this period." : "No keys pressed in this app in this period.")
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
            }

            HStack(spacing: 10) {
                Text("Less").foregroundStyle(.secondary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.heatGradient)
                    .frame(width: 240, height: 10)
                Text("More").foregroundStyle(.secondary)
                Spacer()
                if maxCount > 0 {
                    Text("Hottest key: \(Format.count(maxCount)) presses. Colours use a log scale so quieter keys still show.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if total > 0 {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Most pressed").font(.headline)
                        let top = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(10)
                        ForEach(Array(top), id: \.key) { code, count in
                            HStack(spacing: 10) {
                                KeyChip(code: code).frame(width: 64, alignment: .leading)
                                GeometryReader { geometry in
                                    Capsule()
                                        .fill(Theme.heat(Theme.heatLevel(count, max: maxCount)))
                                        .frame(width: max(4, geometry.size.width * CGFloat(count) / CGFloat(maxCount)))
                                }
                                .frame(height: 8)
                                Text(Format.count(count)).monospacedDigit().frame(width: 70, alignment: .trailing)
                                Text(Format.percent(count, of: total))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 46, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .task(id: reload) {
            counts = model.keyCounts(for: period, app: state.app)
            apps = model.apps(for: period).map { (id: $0.key, use: $0.value) }.sorted { $0.use.keys > $1.use.keys }
        }
    }
}

/// One key of the drawn keyboard.
struct KeySpec: Identifiable {
    let code: UInt16
    let width: Double
    var align: Alignment = .center
    var id: UInt16 { code }
}

/// A Mac ANSI keyboard, 15 units wide.
enum MacKeyboard {
    static let functionRow: [KeySpec] = [KeySpec(code: 53, width: 1.5, align: .bottomLeading)]
        + [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].map { KeySpec(code: $0, width: 1.125) }

    static let rows: [[KeySpec]] = [
        [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24].map { KeySpec(code: $0, width: 1) }
            + [KeySpec(code: 51, width: 2, align: .bottomTrailing)],
        [KeySpec(code: 48, width: 1.5, align: .bottomLeading)]
            + [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30].map { KeySpec(code: $0, width: 1) }
            + [KeySpec(code: 42, width: 1.5)],
        [KeySpec(code: 57, width: 1.75, align: .bottomLeading)]
            + [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39].map { KeySpec(code: $0, width: 1) }
            + [KeySpec(code: 36, width: 2.25, align: .bottomTrailing)],
        [KeySpec(code: 56, width: 2.25, align: .bottomLeading)]
            + [6, 7, 8, 9, 11, 45, 46, 43, 47, 44].map { KeySpec(code: $0, width: 1) }
            + [KeySpec(code: 60, width: 2.75, align: .bottomTrailing)],
    ]

    static let bottomRow: [KeySpec] = [
        KeySpec(code: 63, width: 1, align: .bottomLeading), KeySpec(code: 59, width: 1, align: .bottomLeading),
        KeySpec(code: 58, width: 1, align: .bottomLeading), KeySpec(code: 55, width: 1.25, align: .bottomLeading),
        KeySpec(code: 49, width: 5.5), KeySpec(code: 54, width: 1.25, align: .bottomTrailing),
        KeySpec(code: 61, width: 1, align: .bottomTrailing),
    ]
}

struct KeyboardHeatmap: View {
    let counts: [UInt16: Int]
    let total: Int
    let maxCount: Int
    private let gap: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let unit = (geometry.size.width + gap) / 15
            VStack(alignment: .leading, spacing: gap) {
                row(MacKeyboard.functionRow, unit: unit, height: unit * 0.72)
                ForEach(0..<MacKeyboard.rows.count, id: \.self) { index in
                    row(MacKeyboard.rows[index], unit: unit, height: unit)
                }
                HStack(spacing: gap) {
                    ForEach(MacKeyboard.bottomRow) { key(spec: $0, unit: unit, height: unit) }
                    key(spec: KeySpec(code: 123, width: 1), unit: unit, height: unit * 0.5)
                        .frame(height: unit - gap, alignment: .bottom)
                    VStack(spacing: gap / 2) {
                        key(spec: KeySpec(code: 126, width: 1), unit: unit, height: (unit - gap / 2) / 2 + gap / 2)
                        key(spec: KeySpec(code: 125, width: 1), unit: unit, height: (unit - gap / 2) / 2 + gap / 2)
                    }
                    key(spec: KeySpec(code: 124, width: 1), unit: unit, height: unit * 0.5)
                        .frame(height: unit - gap, alignment: .bottom)
                }
            }
        }
        .aspectRatio(15 / 5.72, contentMode: .fit)
    }

    private func row(_ specs: [KeySpec], unit: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(specs) { key(spec: $0, unit: unit, height: height) }
        }
    }

    private func key(spec: KeySpec, unit: CGFloat, height: CGFloat) -> some View {
        let count = counts[spec.code] ?? 0
        return KeyCapView(code: spec.code, count: count, total: total,
                          level: Theme.heatLevel(count, max: maxCount), align: spec.align,
                          fontSize: max(9, unit * 0.2))
            .frame(width: spec.width * unit - gap, height: height - gap)
    }
}

struct KeyCapView: View {
    let code: UInt16
    let count: Int
    let total: Int
    let level: Double
    let align: Alignment
    let fontSize: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = count > 0
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(pressed ? AnyShapeStyle(Theme.heat(level)) : AnyShapeStyle(Color.primary.opacity(0.06)))
            Text(KeyNames.name(code))
                .font(.system(size: KeyNames.name(code).count > 1 ? fontSize * 0.8 : fontSize, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(pressed ? Theme.heatLabel(level) : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
            if pressed {
                Text(Format.compact(count))
                    .font(.system(size: max(8, fontSize * 0.62), weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.heatLabel(level).opacity(0.85))
                    .padding(.horizontal, 4)
                    .padding(.top, 3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: hovering ? 2 : 0.5))
        .scaleEffect(hovering && !reduceMotion ? 1.05 : 1)
        .zIndex(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(count > 0
              ? "\(KeyNames.full(code)): \(Format.count(count)) presses, \(Format.percent(count, of: total)) of all"
              : "\(KeyNames.full(code)): not pressed")
        .accessibilityElement()
        .accessibilityLabel("\(KeyNames.full(code)), \(count) presses")
    }
}

// MARK: - Apps

struct AppsSection: View {
    enum Sort { case keys, clicks, scroll }

    @ObservedObject var model: AppModel
    @ObservedObject var state: DashboardState
    let period: Period
    let reload: ReloadID
    @State private var apps: [(id: String, use: AppUse)] = []
    @State private var sort = Sort.keys

    var body: some View {
        let sorted = apps.sorted {
            switch sort {
            case .keys: $0.use.keys > $1.use.keys
            case .clicks: $0.use.clicks > $1.use.clicks
            case .scroll: $0.use.scrollMM > $1.use.scrollMM
            }
        }
        let totalKeys = max(1, apps.reduce(0) { $0 + $1.use.keys })
        let maxKeys = max(1, apps.map(\.use.keys).max() ?? 1)
        let maxClicks = max(1, apps.map(\.use.clicks).max() ?? 1)
        let maxScroll = max(1, apps.map(\.use.scrollMM).max() ?? 1)
        VStack(alignment: .leading, spacing: 16) {
            if !model.tracksApps {
                Banner(text: "Per-app tracking is off, so new activity isn't split by app.",
                       action: "Open Settings", perform: state.openSettings)
            }
            if apps.isEmpty {
                Card { EmptyChart(message: "No app data for this period.") }
            } else {
                Text("Counts keys, clicks and scrolling for each app. Only app names are stored, never what you type.")
                    .foregroundStyle(.secondary)
                Card {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Text("App").frame(maxWidth: .infinity, alignment: .leading)
                            sortButton("Keys", .keys).frame(width: 220, alignment: .leading)
                            sortButton("Clicks", .clicks).frame(width: 160, alignment: .leading)
                            sortButton("Scroll", .scroll).frame(width: 140, alignment: .leading)
                        }
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                        Divider()
                        ForEach(sorted, id: \.id) { app in
                            AppRow(id: app.id, use: app.use, share: Format.percent(app.use.keys, of: totalKeys),
                                   keyFraction: Double(app.use.keys) / Double(maxKeys),
                                   clickFraction: Double(app.use.clicks) / Double(maxClicks),
                                   scrollFraction: app.use.scrollMM / maxScroll) {
                                state.app = app.id
                                state.section = .keyboard
                            }
                        }
                    }
                }
            }
        }
        .task(id: reload) {
            apps = model.apps(for: period).map { (id: $0.key, use: $0.value) }
        }
    }

    private func sortButton(_ title: String, _ value: Sort) -> some View {
        Button {
            sort = value
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sort == value { Image(systemName: "arrow.down").font(.caption2.weight(.bold)) }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(sort == value ? .primary : .secondary)
        .help("Sort by \(title.lowercased())")
    }
}

struct AppRow: View {
    let id: String
    let use: AppUse
    let share: String
    let keyFraction: Double
    let clickFraction: Double
    let scrollFraction: Double
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: AppIcons.icon(for: id))
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(use.name).lineLimit(1)
                Text(share).foregroundStyle(.tertiary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BarCell(fraction: keyFraction, color: .blue, label: Format.count(use.keys)).frame(width: 220)
            BarCell(fraction: clickFraction, color: .green, label: Format.count(use.clicks)).frame(width: 160)
            BarCell(fraction: scrollFraction, color: .orange, label: Format.distance(mm: use.scrollMM)).frame(width: 140)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help("Show \(use.name) on the keyboard heatmap")
    }
}

struct BarCell: View {
    let fraction: Double
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geometry in
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(fraction > 0 ? 3 : 0, geometry.size.width * fraction))
                    .frame(maxHeight: .infinity)
            }
            .frame(height: 8)
            Text(label)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 72, alignment: .trailing)
        }
    }
}

enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let icon = cache[bundleID] { return icon }
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        cache[bundleID] = icon
        return icon
    }
}

// MARK: - Calendar

struct CalendarSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: DashboardState
    let reload: ReloadID
    @State private var daily: [String: Counts] = [:]
    @State private var showClicks = false

    var body: some View {
        let metric: (Counts) -> Int = showClicks ? { $0.clicks } : { $0.keys }
        let values = daily.mapValues(metric)
        let total = values.values.reduce(0, +)
        let best = values.max { $0.value < $1.value }
        let active = values.values.filter { $0 > 0 }.count
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Show", selection: $showClicks) {
                    Text("Keys").tag(false)
                    Text("Clicks").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            Card {
                CalendarGrid(year: state.year, calendar: model.calendar, clock: model.clock, values: values,
                             unit: showClicks ? "clicks" : "keys") { date in
                    state.kind = .day
                    state.anchor = date
                    state.section = .overview
                }
            }
            HStack(spacing: 10) {
                Text("Less").foregroundStyle(.secondary)
                ForEach(0..<6) { level in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(CalendarGrid.color(level: level))
                        .frame(width: 14, height: 14)
                }
                Text("More").foregroundStyle(.secondary)
                Spacer()
                Text("Click a day to open it.").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                BigTile(icon: "sum", title: "Total in \(state.year)", value: Format.count(total), detail: showClicks ? "clicks" : "keys")
                BigTile(icon: "flame", title: "Best day", value: best.map { Format.count($0.value) } ?? "–",
                        detail: best.flatMap { dayTitle($0.key) } ?? "No activity yet")
                BigTile(icon: "calendar", title: "Active days", value: "\(active)",
                        detail: active > 0 ? "≈ \(Format.count(total / active)) a day when active" : "No activity yet")
            }
        }
        .task(id: reload) {
            let calendar = model.calendar
            let start = calendar.date(from: DateComponents(year: state.year, month: 1, day: 1))!
            let end = calendar.date(byAdding: .year, value: 1, to: start)!
            daily = model.stats(for: Period(kind: .year, start: start, end: end)).dailyTotals
        }
    }

    private func dayTitle(_ day: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = model.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// A year as a grid of days: one column per week, like a contributions graph.
struct CalendarGrid: View {
    let year: Int
    let calendar: Calendar
    let clock: DayClock
    let values: [String: Int]
    let unit: String
    let open: (Date) -> Void

    private struct Day: Identifiable {
        let date: Date
        let key: String
        let column: Int
        let row: Int
        var id: String { key }
    }

    static func color(level: Int) -> Color {
        level == 0 ? Color.primary.opacity(0.07) : Theme.heat([0.12, 0.35, 0.55, 0.75, 0.95][level - 1])
    }

    var body: some View {
        let days = layout()
        let columns = (days.last?.column ?? 52) + 1
        let thresholds = levels()
        GeometryReader { geometry in
            let labelWidth: CGFloat = 30
            let cell = floor((geometry.size.width - labelWidth) / CGFloat(columns))
            let gap = max(2, cell * 0.18)
            ZStack(alignment: .topLeading) {
                ForEach(monthStarts(days), id: \.column) { month in
                    Text(month.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .offset(x: labelWidth + CGFloat(month.column) * cell, y: 0)
                }
                ForEach([1, 3, 5], id: \.self) { row in
                    Text(weekdayName(row))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .offset(x: 0, y: 18 + CGFloat(row) * cell + (cell - gap) / 2 - 6)
                }
                ForEach(days) { day in
                    let value = values[day.key] ?? 0
                    RoundedRectangle(cornerRadius: max(2, cell * 0.18), style: .continuous)
                        .fill(Self.color(level: level(value, thresholds)))
                        .frame(width: cell - gap, height: cell - gap)
                        .offset(x: labelWidth + CGFloat(day.column) * cell, y: 18 + CGFloat(day.row) * cell)
                        .help("\(day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))): \(Format.count(value)) \(unit)")
                        .onTapGesture { open(day.date) }
                }
            }
        }
        .aspectRatio(CGFloat(columns) / 7.9, contentMode: .fit)
    }

    private func layout() -> [Day] {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(byAdding: .year, value: 1, to: start) else { return [] }
        let firstColumnStart = calendar.dateInterval(of: .weekOfYear, for: start)!.start
        var days: [Day] = []
        var date = start
        let today = Date()
        while date < end && date <= today {
            let offset = calendar.dateComponents([.day], from: firstColumnStart, to: date).day ?? 0
            days.append(Day(date: date, key: clock.day(for: date), column: offset / 7, row: offset % 7))
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
        return days
    }

    /// Value cut-offs for the five colour levels, from the busier and quieter active days.
    private func levels() -> [Int] {
        let active = values.values.filter { $0 > 0 }.sorted()
        guard !active.isEmpty else { return [] }
        return [0.2, 0.4, 0.6, 0.8].map { active[min(active.count - 1, Int(Double(active.count) * $0))] }
    }

    private func level(_ value: Int, _ thresholds: [Int]) -> Int {
        guard value > 0 else { return 0 }
        guard !thresholds.isEmpty else { return 3 }
        return 1 + thresholds.filter { value > $0 }.count
    }

    private func monthStarts(_ days: [Day]) -> [(name: String, column: Int)] {
        days.filter { calendar.component(.day, from: $0.date) == 1 }
            .map { ($0.date.formatted(.dateTime.month(.abbreviated)), $0.column) }
    }

    private func weekdayName(_ row: Int) -> String {
        let symbols = calendar.shortWeekdaySymbols
        return symbols[(calendar.firstWeekday - 1 + row) % 7]
    }
}

// MARK: - Import

enum Importer {
    /// Asks for a backup file, then whether to add it to the current data or replace it.
    static func run(_ model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Keylog backup (made with Export → Full Backup as JSON)."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let ask = NSAlert()
            ask.messageText = "Import “\(url.lastPathComponent)”?"
            ask.informativeText = "Add its counts to what Keylog has now, or replace everything with the backup."
            ask.addButton(withTitle: "Add to Current Data")
            ask.addButton(withTitle: "Replace Current Data")
            ask.addButton(withTitle: "Cancel")
            let choice = ask.runModal()
            guard choice != .alertThirdButtonReturn else { return }
            let replace = choice == .alertSecondButtonReturn
            if replace {
                let confirm = NSAlert()
                confirm.messageText = "Replace all of Keylog's data?"
                confirm.informativeText = "Everything Keylog has now is removed and the backup takes its place. This can't be undone."
                confirm.alertStyle = .critical
                confirm.addButton(withTitle: "Replace")
                confirm.addButton(withTitle: "Cancel")
                guard confirm.runModal() == .alertFirstButtonReturn else { return }
            }
            try model.importBackup(data, replace: replace)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - Export

enum Exporter {
    static func csv(_ model: AppModel) {
        model.recorder.flush(wait: true)
        var days: [String: Counts] = [:]
        for row in model.store.hours(from: "0000-01-01", through: "9999-12-31") {
            days[row.day, default: Counts()].add(row.counts)
        }
        var lines = ["date,keys,letters,numbers,special,space,other,clicks,left_clicks,right_clicks,mouse_metres,scroll_metres,peak_keys_per_second,minutes_typing"]
        for (day, c) in days.sorted(by: { $0.key < $1.key }) {
            let fields: [String] = [
                day, "\(c.keys)", "\(c.letters)", "\(c.numbers)", "\(c.special)", "\(c.space)", "\(c.other)",
                "\(c.clicks)", "\(c.clicksLeft)", "\(c.clicksRight)",
                String(format: "%.2f", c.mouseMM / 1000), String(format: "%.2f", c.scrollMM / 1000),
                "\(c.peakKPS)", "\(c.activeMinutes)",
            ]
            lines.append(fields.joined(separator: ","))
        }
        save(Data((lines.joined(separator: "\n") + "\n").utf8), name: "Keylog daily totals.csv", type: .commaSeparatedText)
    }

    static func json(_ model: AppModel) {
        model.recorder.flush(wait: true)
        var backup: [String: Any] = model.store.backup()
        backup["format"] = "keylog-backup-1"
        backup["exported"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: backup, options: [.prettyPrinted, .sortedKeys]) else { return }
        save(data, name: "Keylog backup.json", type: .json)
    }

    private static func save(_ data: Data, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
