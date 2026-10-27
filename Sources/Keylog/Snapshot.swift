import AppKit
import KeylogCore
import SwiftUI

/// `Keylog --snapshot <folder>` renders every screen with demo data into 2× PNGs:
/// one image per screen for design checks, and the composed README screenshots.
/// It uses a throwaway database and never touches real data.
enum Snapshot {
    /// True while rendering. Glass can't be captured offscreen, so glass surfaces
    /// draw an opaque stand-in, and the dashboard draws its own sidebar.
    static private(set) var isRendering = false

    static func run(into folder: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        isRendering = true
        let out = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let path = NSTemporaryDirectory() + "keylog-snapshot-\(UUID().uuidString).sqlite"
        let store = try! Store(path: path)
        let clock = DayClock()
        DemoData.seed(store, clock: clock)
        let recorder = Recorder(store: store, clock: clock)
        let model = AppModel(store: store, recorder: recorder)
        model.setCounting(true)
        model.publish()
        model.widget.isVisible = true
        model.widget.apply(.darkGlass)
        let actions = AppActions()
        let feed = PanelFeed()
        feed.sync(from: model)

        func dashboard(_ section: DashboardSection, _ kind: PeriodKind) -> DashboardView {
            let state = DashboardState()
            state.section = section
            state.kind = kind
            return DashboardView(model: model, state: state)
        }
        let panel = PopoverView(model: model, feed: feed, actions: actions).modifier(GlassBackground())

        // One image per screen.
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            render(panel, to: out, "panel-\(mode)", dark: dark)
            for section in DashboardSection.allCases {
                render(dashboard(section, section == .overview ? .day : .month), size: CGSize(width: 1100, height: 900),
                       to: out, "dashboard-\(section.rawValue)-\(mode)", dark: dark)
            }
        }
        // A stacked chart with one bar hovered: dimming, outline and tooltip.
        let recent = model.stats(for: model.recentDays(20))
        for dark in [false, true] {
            render(Card { ActivityChart(stats: recent, stacked: true, metric: .keys, pinnedHover: 14).frame(height: 240) }
                    .padding(24).frame(width: 640).background(Color(nsColor: .windowBackgroundColor)),
                   to: out, "chart-hover-\(dark ? "dark" : "light")", dark: dark)
        }
        for tab in SettingsTab.allCases {
            render(tab.content(model: model, actions: actions), size: CGSize(width: 560, height: tab.height),
                   to: out, "settings-\(tab.rawValue)", dark: false)
        }
        let onboarding = OnboardingModel()
        for state in [OnboardingModel.State.intro, .waiting, .granted, .needsRestart] {
            onboarding.state = state
            render(OnboardingView(model: onboarding, openSettings: {}, restart: {}), to: out, "onboarding-\(state)", dark: false)
        }

        // README screenshots.
        let readme = out.appendingPathComponent("readme")
        try? FileManager.default.createDirectory(at: readme, withIntermediateDirectories: true)
        render(HeroScene(dashboard: dashboard(.overview, .week), panel: panel, widget: WidgetView(model: model),
                         keys: model.today.keys),
               to: readme, "hero", dark: true)
        let windows: [(String, DashboardSection, PeriodKind, Bool, CGFloat)] = [
            ("overview", .overview, .week, false, 900), ("keyboard", .keyboard, .month, false, 780),
            ("apps", .apps, .month, true, 520), ("calendar", .calendar, .year, false, 600), ("mouse", .mouse, .month, true, 760),
        ]
        for (name, section, kind, dark, height) in windows {
            render(Showcase { MacWindow { dashboard(section, kind) }.frame(width: 1100, height: height) },
                   to: readme, name, dark: dark)
        }
        render(Showcase {
            HStack(alignment: .top, spacing: 48) {
                panel.environment(\.colorScheme, .light)
                panel.environment(\.colorScheme, .dark)
            }
        }, to: readme, "panel", dark: false)
        let widgets = [WidgetStyle.Preset.darkGlass, .lightGlass, .textOnly].map { preset in
            var style = model.widget
            style.apply(preset)
            style.fontSize = 32
            return WidgetPreview(style: style, keys: model.today.keys)
        }
        render(Showcase(padding: 56) {
            HStack(spacing: 40) { ForEach(widgets.indices, id: \.self) { widgets[$0] } }
        }, to: readme, "widget", dark: false)
        render(SocialScene(panel: panel), to: readme, "social", dark: true)
        render(Showcase { MacWindow(title: "Widget") { SettingsTab.widget.content(model: model, actions: actions) }
                    .frame(width: 560, height: 615) },
               to: readme, "settings", dark: false)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    /// Renders a view at 2× and writes `<name>.png`.
    private static func render<V: View>(_ view: V, size: CGSize? = nil, to folder: URL, _ name: String, dark: Bool) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        let window = RetinaWindow(contentRect: CGRect(x: -30000, y: -30000, width: 400, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let fitted = size ?? host.fittingSize
        window.setContentSize(fitted)
        host.frame = CGRect(origin: .zero, size: fitted)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(fitted.width * 2), pixelsHigh: Int(fitted.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = fitted
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
        window.orderOut(nil)
    }
}

/// An offscreen window that renders as if on a Retina display.
private final class RetinaWindow: NSWindow {
    override var backingScaleFactor: CGFloat { 2 }
}

/// A static copy of the widget for screenshots of several styles side by side.
private struct WidgetPreview: View {
    let style: WidgetStyle
    let keys: Int

    var body: some View {
        HStack(spacing: style.fontSize * 0.35) {
            if style.content == .icon {
                Image(systemName: "keyboard")
                    .font(.system(size: style.fontSize * 0.72, weight: .medium))
                    .opacity(0.75)
            }
            Text(Format.count(keys)).font(style.swiftUIFont).monospacedDigit()
        }
        .foregroundStyle(style.text.color)
        .padding(.horizontal, style.shape == .none ? 6 : style.fontSize * 0.62)
        .padding(.vertical, style.shape == .none ? 3 : style.fontSize * 0.3)
        .background {
            if style.shape != .none {
                Capsule(style: .continuous).fill(style.background.color.opacity(max(style.backgroundOpacity, 0.7)))
            }
        }
        .shadow(color: .black.opacity(style.shape == .none ? 0.55 : 0), radius: 2, y: 1)
    }
}

/// A soft macOS-style wallpaper.
struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.2, green: 0.16, blue: 0.42), Color(red: 0.1, green: 0.22, blue: 0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.98, green: 0.5, blue: 0.42).opacity(0.85), .clear],
                           center: UnitPoint(x: 0.85, y: 0.95), startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Color(red: 0.35, green: 0.55, blue: 1).opacity(0.7), .clear],
                           center: UnitPoint(x: 0.1, y: 0.05), startRadius: 0, endRadius: 650)
            RadialGradient(colors: [Color(red: 0.75, green: 0.35, blue: 0.85).opacity(0.55), .clear],
                           center: UnitPoint(x: 0.55, y: 0.45), startRadius: 0, endRadius: 520)
        }
    }
}

/// A view centred on the wallpaper with room around it.
struct Showcase<Content: View>: View {
    var padding: CGFloat = 64
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Wallpaper())
    }
}

/// A window frame with traffic lights, for screenshots.
struct MacWindow<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if let title {
                ZStack {
                    Text(title).font(.headline)
                    HStack { lights; Spacer() }
                }
                .frame(height: 52)
                .padding(.horizontal, 20)
                .background(Color(nsColor: .windowBackgroundColor))
                content.background(Color(nsColor: .windowBackgroundColor))
            } else {
                content.overlay(alignment: .topLeading) { lights.padding(.leading, 20).padding(.top, 20) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 34, y: 20)
    }

    private var lights: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
            Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
            Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
        }
        .frame(width: 52, height: 12)
    }
}

/// The 1280 × 640 card GitHub shows when the repo link is shared.
struct SocialScene<Panel: View>: View {
    let panel: Panel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 20) {
                    Image(nsImage: NSImage(contentsOfFile: "Resources/AppIcon.png") ?? NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 132, height: 132)
                    Text("Keylog")
                        .font(.system(size: 84, weight: .bold, design: .rounded))
                }
                Text("The private keystroke counter\nand keyboard heatmap for macOS")
                    .font(.system(size: 36, weight: .semibold))
                    .lineSpacing(4)
                    .opacity(0.95)
                HStack(spacing: 10) {
                    ForEach(["Typing speed & WPM", "Keyboard heatmap", "100% offline", "Open source"], id: \.self) { label in
                        Text(label)
                            .font(.system(size: 19, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.16), in: Capsule())
                    }
                }
                Text("Every key you press, counted. Never recorded.")
                    .font(.system(size: 22, weight: .medium))
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.leading, 72)
            .padding(.top, 92)

            panel
                .fixedSize()
                .scaleEffect(0.7, anchor: .topLeading)
                .frame(width: 252, height: 600, alignment: .topLeading)
                .offset(x: 970, y: 34)
        }
        .frame(width: 1280, height: 640)
        .clipped()
    }
}

/// The opening README image: a desktop with the dashboard, the panel and the widget.
struct HeroScene<Dashboard: View, Panel: View, Widget: View>: View {
    let dashboard: Dashboard
    let panel: Panel
    let widget: Widget
    let keys: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            Wallpaper()
            // Menu bar
            HStack(spacing: 18) {
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "keyboard")
                    Text(Format.count(keys)).monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text("Wed 21 Oct  4:20 PM")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 30)
            .background(.black.opacity(0.22))

            MacWindow { dashboard }
                .frame(width: 1100, height: 800)
                .scaleEffect(0.86, anchor: .topLeading)
                .offset(x: 48, y: 84)

            panel
                .scaleEffect(0.86, anchor: .topTrailing)
                .frame(width: 360, height: 800, alignment: .topTrailing)
                .offset(x: 1600 - 360 - 30, y: 38)

            widget
                .scaleEffect(1.5)
                .offset(x: 1000, y: 800)
        }
        .frame(width: 1600, height: 900)
        .clipped()
    }
}

/// 400 days of believable activity for screenshots and checks. Deterministic.
enum DemoData {
    private struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// Key codes weighted by how often English uses them.
    private static let letters: [(UInt16, Double)] = [
        (14, 12.7), (17, 9.1), (0, 8.2), (31, 7.5), (34, 7.0), (45, 6.7), (1, 6.3), (4, 6.1), (15, 6.0),
        (2, 4.3), (37, 4.0), (8, 2.8), (32, 2.8), (46, 2.4), (13, 2.4), (3, 2.2), (5, 2.0), (16, 2.0),
        (35, 1.9), (11, 1.5), (9, 1.0), (40, 0.8), (38, 0.2), (7, 0.2), (12, 0.1), (6, 0.1),
    ]
    private static let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    private static let specials: [(UInt16, Double)] = [(47, 5), (43, 4), (41, 2), (39, 2), (27, 2), (44, 1.5), (24, 1), (33, 1), (30, 1)]
    private static let others: [(UInt16, Double)] = [(51, 10), (36, 5), (48, 2), (53, 1), (123, 1), (124, 1), (125, 1), (126, 1)]
    private static let apps: [(String, String, Double)] = [
        ("com.apple.dt.Xcode", "Xcode", 0.3), ("com.apple.Safari", "Safari", 0.22), ("com.apple.Notes", "Notes", 0.14),
        ("com.apple.mail", "Mail", 0.12), ("com.apple.MobileSMS", "Messages", 0.12), ("com.apple.Terminal", "Terminal", 0.1),
    ]
    private static let curve: [Int: Double] = [
        8: 0.2, 9: 0.6, 10: 0.9, 11: 1.0, 12: 0.7, 13: 0.35, 14: 0.8, 15: 0.95, 16: 1.0, 17: 0.8,
        18: 0.45, 19: 0.3, 20: 0.4, 21: 0.5, 22: 0.35, 23: 0.15,
    ]

    static func seed(_ store: Store, clock: DayClock, days: Int = 400, now: Date = Date()) {
        var random = Random(state: 42)
        let calendar = clock.calendar
        let today = calendar.startOfDay(for: now)
        for back in (0..<days).reversed() {
            let day = calendar.date(byAdding: .day, value: -back, to: today)!
            let weekday = calendar.component(.weekday, from: day)
            if random.next() < 0.06 { continue }
            let dayScale = (weekday == 1 || weekday == 7 ? 0.3 : 1.0) * (0.5 + random.next())
            for (hour, weight) in curve.sorted(by: { $0.key < $1.key }) {
                let date = calendar.date(byAdding: .hour, value: hour, to: day)!
                guard date <= now else { break }
                let keys = Int(weight * dayScale * 1400 * (0.6 + 0.8 * random.next()))
                guard keys > 20 else { continue }
                var flush = HourFlush(bucket: clock.bucket(for: date))
                flush.counts.letters = keys * 71 / 100
                flush.counts.numbers = keys * 4 / 100
                flush.counts.special = keys * 7 / 100
                flush.counts.space = keys * 14 / 100
                flush.counts.other = keys - flush.counts.letters - flush.counts.numbers - flush.counts.special - flush.counts.space
                flush.counts.clicksLeft = keys / 9
                flush.counts.clicksRight = keys / 140
                flush.counts.mouseMM = Double(keys) * (4 + 4 * random.next())
                flush.counts.scrollMM = Double(keys) * (1 + random.next())
                flush.counts.peakKPS = 6 + Int(random.next() * 9)
                flush.counts.peakCPS = 3 + Int(random.next() * 6)
                let minutes = min(60, keys / 90 + 5)
                for _ in 0..<minutes { flush.minutesMask |= 1 << UInt64(Int(random.next() * 60)) }

                let primary = pick(apps.map { ($0, $0.2) }, &random)
                let secondary = pick(apps.map { ($0, $0.2) }, &random)
                for (app, share) in [(primary, 0.7), (secondary, 0.3)] {
                    var use = flush.apps[app.0] ?? AppUse(name: app.1)
                    use.keys += Int(Double(keys) * share)
                    use.clicks += Int(Double(flush.counts.clicksLeft) * share)
                    use.scrollMM += flush.counts.scrollMM * share
                    flush.apps[app.0] = use
                    func spread(_ total: Int, _ codes: [(UInt16, Double)]) {
                        let sum = codes.reduce(0) { $0 + $1.1 }
                        for (code, w) in codes {
                            let n = Int(Double(total) * share * w / sum)
                            if n > 0 { flush.keys[KeyUse(app: app.0, key: code), default: 0] += n }
                        }
                    }
                    spread(flush.counts.letters, letters)
                    spread(flush.counts.numbers, digits.map { ($0, 1) })
                    spread(flush.counts.special, specials)
                    spread(flush.counts.space, [(49, 1)])
                    spread(flush.counts.other, others)
                    spread(keys / 25, [(56, 3), (55, 2), (58, 0.5), (59, 0.3)])
                }
                store.write(flush)
            }
        }
        store.sync()
    }

    private static func pick<T>(_ items: [(T, Double)], _ random: inout Random) -> T {
        var roll = random.next() * items.reduce(0) { $0 + $1.1 }
        for (item, weight) in items {
            roll -= weight
            if roll <= 0 { return item }
        }
        return items.last!.0
    }
}
