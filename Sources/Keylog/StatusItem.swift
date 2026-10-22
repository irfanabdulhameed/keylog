import AppKit
import Combine
import KeylogCore
import SwiftUI

/// What the views can ask the app to do.
struct AppActions {
    var openDashboard: (DashboardSection) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var allowAccess: () -> Void = {}
    var moveWidget: () -> Void = {}
    var quit: () -> Void = { NSApp.terminate(nil) }
}

/// The menu bar item. Click opens the frosted-glass panel; right-click or
/// Control-click opens a short menu.
final class StatusItemController: NSObject {
    private let model: AppModel
    private var actions: AppActions
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let feed = PanelFeed()
    private var panel: GlassPanel!
    private var isPanelOpen = false
    private var lastRender = ""
    private var outsideClickMonitor: Any?
    private var menuClickMonitor: Any?
    private var subscriptions: Set<AnyCancellable> = []

    init(model: AppModel, actions: AppActions) {
        self.model = model
        self.actions = actions
        super.init()

        // Close the panel before anything opens a window.
        self.actions.openDashboard = { [weak self] section in
            self?.closePanel()
            actions.openDashboard(section)
        }
        self.actions.openSettings = { [weak self] in
            self?.closePanel()
            actions.openSettings()
        }
        self.actions.allowAccess = { [weak self] in
            self?.closePanel()
            actions.allowAccess()
        }
        self.actions.moveWidget = { [weak self] in
            self?.closePanel()
            actions.moveWidget()
        }

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp])
            button.imagePosition = .imageLeading
        }

        // macOS treats right-click and Control-click on the icon as a menu request and
        // never sends them to the button's action, so catch the mouse-down here.
        menuClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let button = self.item.button, event.window === button.window,
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            else { return event }
            self.showMenu()
            return nil
        }

        Publishers.CombineLatest4(model.$today, model.$menuBarDisplay, model.$isPaused, model.$isCounting)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }
            .store(in: &subscriptions)
        Publishers.CombineLatest(model.$liveKPM, model.$tintBySpeed)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }
            .store(in: &subscriptions)
        model.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.isPanelOpen else { return }
                    self.feed.sync(from: self.model)
                }
            }
            .store(in: &subscriptions)

        // Built once and kept, so it opens instantly. Hidden, it gets no updates.
        let host = NSHostingController(rootView: PopoverView(model: model, feed: feed, actions: self.actions).modifier(GlassBackground()))
        host.sizingOptions = [.preferredContentSize]
        panel = GlassPanel(contentViewController: host)
        panel.onClose = { [weak self] in self?.closePanel() }
        // Draw it once offscreen shortly after launch, so even the first click is instant.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.isPanelOpen else { return }
            self.feed.sync(from: self.model)
            self.panel.alphaValue = 0
            self.panel.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            self.panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !self.isPanelOpen { self.panel.orderOut(nil) }
            }
        }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if isPanelOpen {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func showMenu() {
        closePanel()
        item.menu = contextMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    // MARK: Glass panel

    private func openPanel() {
        guard let button = item.button, let buttonWindow = button.window else { return }
        model.recorder.tick()
        model.publish()
        isPanelOpen = true
        feed.sync(from: model)
        feed.openCount += 1

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panel.anchor = NSPoint(x: buttonFrame.midX, y: buttonFrame.minY - 6)
        panel.fitContent()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        // A click anywhere outside Keylog closes the panel, like a menu.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func closePanel() {
        guard isPanelOpen else { return }
        isPanelOpen = false
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        item.button?.highlight(false)
        let panel = panel!
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.isPanelOpen == false { panel.orderOut(nil) }
        })
    }

    // MARK: Menu

    private func contextMenu() -> NSMenu {
        KeylogMenu.make(model: model, actions: actions)
    }

    // MARK: Menu bar title

    private func render() {
        guard let button = item.button else { return }
        let today = model.today
        // Skip the redraw when nothing visible has changed (mouse travel, say).
        let speedLevel = model.tintBySpeed ? Self.speedLevel(model.liveKPM) : nil
        let signature = "\(model.menuBarDisplay)|\(model.isPaused)|\(model.isCounting)|\(today.keys)|\(speedLevel ?? -1)|"
            + (model.menuBarDisplay == .keysAndClicks ? Format.compact(today.clicks) : "")
        guard signature != lastRender else { return }
        lastRender = signature
        button.contentTintColor = speedLevel.map { NSColor(Theme.heat($0)) }
        button.appearsDisabled = model.isPaused || !model.isCounting
        button.toolTip = model.isCounting
            ? "Keylog: \(Format.count(today.keys)) keys, \(Format.count(today.clicks)) clicks today"
            : "Keylog: not counting"
        let symbol = model.isPaused ? "pause.circle" : "keyboard"
        switch model.menuBarDisplay {
        case .icon:
            button.image = Self.symbol(symbol)
            button.attributedTitle = NSAttributedString()
        case .keys:
            button.image = Self.symbol(symbol)
            button.attributedTitle = NSAttributedString(
                string: model.isCounting ? Format.count(today.keys) : "–",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)])
        case .keysAndClicks:
            button.image = Self.stacked(symbol: symbol, top: Format.compact(today.keys), bottom: Format.compact(today.clicks))
            button.attributedTitle = NSAttributedString()
        }
    }

    /// Heat level for a typing speed: nothing below 120 keys a minute, then green
    /// through yellow and orange to red at 360 and up. Steps of 0.05 limit redraws.
    private static func speedLevel(_ keysPerMinute: Int) -> Double? {
        guard keysPerMinute >= 120 else { return nil }
        let t = min(1, Double(keysPerMinute - 120) / 240)
        return ((0.55 + 0.45 * t) * 20).rounded() / 20
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Keylog")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        image?.isTemplate = true
        return image
    }

    /// The icon with keys over clicks in two small lines, drawn as one template image.
    private static func stacked(symbol name: String, top: String, bottom: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let topText = NSAttributedString(string: top, attributes: attributes)
        let bottomText = NSAttributedString(string: bottom, attributes: attributes)
        let icon = symbol(name)
        let iconSize = icon?.size ?? .zero
        let textWidth = ceil(max(topText.size().width, bottomText.size().width))
        let size = NSSize(width: iconSize.width + 4 + textWidth, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            icon?.draw(in: NSRect(x: 0, y: (22 - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
            topText.draw(at: NSPoint(x: iconSize.width + 4, y: 10.5))
            bottomText.draw(at: NSPoint(x: iconSize.width + 4, y: 0.5))
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The values the panel shows. Synced from the app model only while the panel is
/// open, so a hidden panel never redraws.
final class PanelFeed: ObservableObject {
    @Published private(set) var today = Counts()
    @Published private(set) var todayKeys: [UInt16: Int] = [:]
    @Published private(set) var isPaused = false
    @Published private(set) var isCounting = false
    @Published private(set) var widgetVisible = true
    @Published private(set) var liveKPM = 0
    /// Bumped on every open, so the panel reloads its charts.
    @Published var openCount = 0

    func sync(from model: AppModel) {
        if today != model.today { today = model.today }
        if todayKeys != model.todayKeys { todayKeys = model.todayKeys }
        if isPaused != model.isPaused { isPaused = model.isPaused }
        if isCounting != model.isCounting { isCounting = model.isCounting }
        if widgetVisible != model.widget.isVisible { widgetVisible = model.widget.isVisible }
        if liveKPM != model.liveKPM { liveKPM = model.liveKPM }
    }
}

/// Borderless floating panel under the menu bar icon. It keeps its top edge
/// pinned under the icon as its content grows or shrinks.
final class GlassPanel: NSPanel {
    var onClose: () -> Void = {}
    var anchor = NSPoint.zero
    private var resizeObserver: NSObjectProtocol?

    convenience init(contentViewController: NSViewController) {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.contentViewController = contentViewController
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        // The window's own shadow traces its rectangle, which shows as a square edge
        // around the rounded corners. Liquid Glass brings its own edge and depth, so
        // drop the window shadow there; everywhere, clip to the rounded shape.
        let radius: CGFloat
        if #available(macOS 26, *) {
            hasShadow = false
            radius = 22
        } else {
            hasShadow = true
            radius = 16
        }
        let view = contentViewController.view
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: self, queue: .main
        ) { [weak self] _ in self?.place() }
        // The window doesn't follow its SwiftUI content's size by itself; follow it here.
        sizeObservation = contentViewController.observe(\.preferredContentSize) { [weak self] _, _ in
            DispatchQueue.main.async { self?.fitContent() }
        }
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }

    private var sizeObservation: NSKeyValueObservation?

    /// Sizes the panel to its content and keeps it under the icon.
    func fitContent() {
        guard let view = contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        if size.width > 0, size.height > 0, size != frame.size {
            setContentSize(size)
        }
        place()
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose() }

    /// Centres the panel under the anchor, kept inside the screen.
    func place() {
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        var x = anchor.x - size.width / 2
        x = min(max(x, area.minX + 8), area.maxX - size.width - 8)
        let y = max(anchor.y - size.height, area.minY + 8)
        let origin = NSPoint(x: x.rounded(), y: y.rounded())
        if frame.origin != origin { setFrameOrigin(origin) }
        invalidateShadow()
    }
}

/// Frosted glass behind the panel's content, with rounded corners and a fine edge.
/// Liquid Glass on macOS 26; frosted blur before that.
struct GlassBackground: ViewModifier {
    func body(content: Content) -> some View {
        if Snapshot.isRendering {
            // Glass can't be captured offscreen; draw an opaque stand-in for screenshots.
            content
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.97),
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            content
                .background(VisualEffectBlur(material: .popover, cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// The glass prominent button on macOS 26; the filled accent button before that.
struct ProminentButton: ViewModifier {
    func body(content: Content) -> some View {
        if Snapshot.isRendering {
            content.buttonStyle(SnapshotProminentStyle())
        } else if #available(macOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

/// A filled accent button that screenshots can capture.
private struct SnapshotProminentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.accentColor, in: Capsule())
    }
}

/// The short menu shared by the menu bar icon and the floating widget.
enum KeylogMenu {
    static func make(model: AppModel, actions: AppActions) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ key: String = "", _ handler: @escaping () -> Void) {
            menu.addItem(ClosureMenuItem(title: title, keyEquivalent: key, handler: handler))
        }
        add("Open Dashboard") { actions.openDashboard(.overview) }
        add("Keyboard Heatmap") { actions.openDashboard(.keyboard) }
        menu.addItem(.separator())
        add(model.widget.isVisible ? "Hide Widget" : "Show Widget") { model.widget.isVisible.toggle() }
        add("Move Widget") { actions.moveWidget() }
        menu.addItem(.separator())
        if !model.isCounting {
            add("Allow Input Monitoring…") { actions.allowAccess() }
        }
        add(model.isPaused ? "Resume Counting" : "Pause Counting") { model.isPaused.toggle() }
        add("Settings…", ",") { actions.openSettings() }
        menu.addItem(.separator())
        add("Quit Keylog", "q") { actions.quit() }
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
