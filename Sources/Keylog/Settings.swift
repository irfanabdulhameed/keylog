import AppKit
import KeylogCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, widget, tracking, data
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .widget: "pip"
        case .tracking: "hand.raised"
        case .data: "externaldrive"
        }
    }
    /// Each tab's window height; the window resizes as you switch tabs.
    var height: CGFloat {
        switch self {
        case .general: 820
        case .widget: 660
        case .tracking: 520
        case .data: 480
        }
    }

    func content(model: AppModel, actions: AppActions) -> AnyView {
        switch self {
        case .general: AnyView(GeneralSettings(model: model, actions: actions))
        case .widget: AnyView(WidgetSettings(model: model, actions: actions))
        case .tracking: AnyView(TrackingSettings(model: model))
        case .data: AnyView(DataSettings(model: model))
        }
    }
}

/// A standard Mac settings window: icon tabs in the toolbar, resizing per tab.
final class SettingsController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let actions: () -> AppActions
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    init(model: AppModel, actions: @escaping () -> AppActions) {
        self.model = model
        self.actions = actions
    }

    func show(_ tab: SettingsTab = .general) {
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.transitionOptions = [.crossfade, .allowUserInteraction]
            tabs.canPropagateSelectedChildViewControllerTitle = true
            for tab in SettingsTab.allCases {
                let host = NSHostingController(rootView: tab.content(model: model, actions: actions()))
                host.sizingOptions = []
                host.preferredContentSize = NSSize(width: 560, height: tab.height)
                host.title = tab.title
                let item = NSTabViewItem(viewController: host)
                item.label = tab.title
                item.image = NSImage(systemSymbolName: tab.icon, accessibilityDescription: tab.title)
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.tabs = tabs
            self.window = window
            tabs.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
            window.center()
        } else {
            tabs?.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        tabs = nil
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    let actions: AppActions
    @AppStorage("heatStyle") private var heatStyle = HeatStyle.solid
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open Keylog when you log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Pause counting", isOn: $model.isPaused)
            }
            Section("Menu bar") {
                Picker("Show", selection: $model.menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Colour the icon by typing speed", isOn: $model.tintBySpeed)
                Text("Green when you type quickly, then yellow, orange and red as you speed up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Picker("Keys milestone", selection: $model.keyMilestone) {
                    Text("Off").tag(0)
                    ForEach([5_000, 10_000, 25_000, 50_000], id: \.self) { Text("Every \(Format.count($0))").tag($0) }
                }
                Picker("Clicks milestone", selection: $model.clickMilestone) {
                    Text("Off").tag(0)
                    ForEach([1_000, 2_500, 5_000], id: \.self) { Text("Every \(Format.count($0))").tag($0) }
                }
                Text("A notification each time today's count passes a milestone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Dashboard") {
                Picker("Weeks start on", selection: $model.weekStart) {
                    ForEach(WeekStart.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Keyboard heatmap") {
                    HStack(spacing: 10) {
                        Text(heatStyle.title).foregroundStyle(.secondary)
                        Button("Customize Keyboard…", action: actions.customizeKeyboard)
                    }
                }
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $model.checksForUpdates)
                Text("Off until you switch it on. Then Keylog asks GitHub for its list of releases about every 6 hours, on Wi-Fi or Ethernet only. The request says which version you have and nothing else: no counts, keys or app names.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(AppVersion.text).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now", action: actions.checkForUpdates)
                }
            }
            Section("Counting rules") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Holding a key down counts once.")
                    Text("⌘ ⇧ ⌥ ⌃ count only when tapped on their own, not in shortcuts.")
                    Text("Password fields are hidden from every app by macOS, so they aren't counted.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS didn't allow this: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct WidgetSettings: View {
    @ObservedObject var model: AppModel
    let actions: AppActions

    var body: some View {
        VStack(spacing: 0) {
            // Live preview on a busy backdrop, so contrast problems show.
            ZStack {
                LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.85), Color(red: 0.95, green: 0.55, blue: 0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                WidgetView(model: model, isPreview: true)
            }
            .frame(height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Form {
                Section {
                    Toggle("Show floating widget", isOn: $model.widget.isVisible)
                    Picker("Style", selection: Binding(get: { model.widget.preset }, set: { model.widget.apply($0) })) {
                        ForEach(WidgetStyle.Preset.allCases) { Text($0.title).tag($0) }
                    }
                    HStack {
                        Button("Move Widget…", action: actions.moveWidget)
                        Text("Drag it anywhere; it snaps to corners.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Text") {
                    Picker("Shows", selection: custom(\.content)) {
                        ForEach(WidgetStyle.Content.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Number", selection: custom(\.compactNumber)) {
                        Text("12,438").tag(false)
                        Text("12.4k").tag(true)
                    }
                    Picker("Font", selection: custom(\.font)) {
                        ForEach(WidgetStyle.FontChoice.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Weight", selection: custom(\.weight)) {
                        ForEach(WidgetStyle.Weight.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Size") {
                        HStack {
                            Slider(value: custom(\.fontSize), in: 12...48, step: 1)
                            Text("\(Int(model.widget.fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    ColorPicker("Colour", selection: colour(\.text), supportsOpacity: false)
                }
                Section("Background") {
                    Picker("Shape", selection: custom(\.shape)) {
                        ForEach(WidgetStyle.Shape.allCases) { Text($0.title).tag($0) }
                    }
                    if model.widget.shape != .none {
                        if model.widget.shape == .rounded {
                            LabeledContent("Corner radius") {
                                Slider(value: custom(\.cornerRadius), in: 0...24, step: 1)
                            }
                        }
                        ColorPicker("Colour", selection: colour(\.background), supportsOpacity: false)
                        LabeledContent("Opacity") {
                            HStack {
                                Slider(value: custom(\.backgroundOpacity), in: 0...1)
                                Text(Format.percent(Int(model.widget.backgroundOpacity * 100), of: 100))
                                    .monospacedDigit().frame(width: 44, alignment: .trailing)
                            }
                        }
                        Toggle("Blur what's behind", isOn: custom(\.blur))
                    }
                }
                Section("Behaviour") {
                    Toggle("Clicks pass through to what's behind", isOn: $model.widget.clickThrough)
                    Text(model.widget.clickThrough
                         ? "Hold ⌃ Control and click the widget for its menu."
                         : "Click the widget to open the dashboard. Right-click or ⌃-click for its menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Fade when the pointer is over it", isOn: $model.widget.fadeOnHover)
                    if model.widget.fadeOnHover {
                        LabeledContent("Faded opacity") {
                            HStack {
                                Slider(value: $model.widget.hoverOpacity, in: 0...0.8)
                                Text(Format.percent(Int(model.widget.hoverOpacity * 100), of: 100))
                                    .monospacedDigit().frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                    Toggle("Pulse on each key press", isOn: $model.widget.pulseOnKey)
                    if model.widget.pulseOnKey {
                        Picker("Pulse size", selection: $model.widget.pulseScale) {
                            Text("102%").tag(1.02)
                            Text("105%").tag(1.05)
                            Text("107%").tag(1.07)
                        }
                        .pickerStyle(.segmented)
                        Text("A tiny grow-and-settle as you type. Off when Reduce Motion is on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Show over full-screen apps", isOn: $model.widget.overFullScreen)
                    Toggle("Show on every desktop", isOn: $model.widget.allDesktops)
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A binding that marks the style as custom once the user changes it.
    private func custom<Value>(_ path: WritableKeyPath<WidgetStyle, Value>) -> Binding<Value> {
        Binding(
            get: { model.widget[keyPath: path] },
            set: {
                model.widget[keyPath: path] = $0
                model.widget.preset = .custom
            })
    }

    private func colour(_ path: WritableKeyPath<WidgetStyle, RGBA>) -> Binding<Color> {
        Binding(
            get: { model.widget[keyPath: path].color },
            set: {
                model.widget[keyPath: path] = RGBA($0)
                model.widget.preset = .custom
            })
    }
}

struct TrackingSettings: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Count keys for each app", isOn: $model.tracksApps)
                Text("Stores the app's name next to its counts, so the Apps view and the heatmap filter work.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Measure mouse travel and scrolling", isOn: $model.tracksMouse)
                Text("Clicks are always counted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach($model.keyboards) { $keyboard in
                    Toggle(keyboard.name, isOn: $keyboard.counts)
                }
            } header: {
                Text("Keyboards")
            } footer: {
                Text("Keyboards appear here when they first send a key. Mouse tools such as USB Overdrive turn side buttons into keyboard shortcuts through a virtual keyboard; it's off so those don't count.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("What Keylog stores") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("How many times each key was pressed, per hour and per app.", systemImage: "checkmark")
                    Label("Clicks, mouse travel, scrolling and typing speed.", systemImage: "checkmark")
                    Label("Never the text you type, the order of keys, or where you click.", systemImage: "xmark")
                    Label("Nothing leaves your Mac. Keylog has no network code.", systemImage: "lock")
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DataSettings: View {
    @ObservedObject var model: AppModel
    @State private var confirmingDelete = false
    @State private var confirmingReset = false
    @State private var confirmingDeleteAgain = false

    var body: some View {
        Form {
            Section("Your data") {
                LabeledContent("File") {
                    Text(model.store.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.store.path)])
                }
            }
            Section("Export and import") {
                Button("Daily Totals as CSV…") { Exporter.csv(model) }
                Button("Full Backup as JSON…") { Exporter.json(model) }
                Button("Import Backup…") { Importer.run(model) }
            }
            Section {
                Button("Reset Today…", role: .destructive) { confirmingReset = true }
                Button("Delete All Data…", role: .destructive) { confirmingDelete = true }
                Text("Removes every count since the first day. Settings are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Reset today's counts?", isPresented: $confirmingReset) {
            Button("Reset Today", role: .destructive) { model.resetToday() }
        } message: {
            Text("Today starts again from zero. Earlier days are kept.")
        }
        .confirmationDialog("Delete all of Keylog's data?", isPresented: $confirmingDelete) {
            Button("Continue…", role: .destructive) { confirmingDeleteAgain = true }
        } message: {
            Text("Every count since the first day will be removed. You may want to export a backup first.")
        }
        .alert("This can't be undone", isPresented: $confirmingDeleteAgain) {
            Button("Delete Everything", role: .destructive) { model.deleteAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keylog will start counting again from zero.")
        }
    }
}
