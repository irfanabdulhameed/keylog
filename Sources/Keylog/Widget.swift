import AppKit
import Combine
import KeylogCore
import SwiftUI

/// How the floating widget looks and behaves. Saved as JSON in preferences.
struct WidgetStyle: Codable, Equatable {
    enum Preset: String, Codable, CaseIterable, Identifiable {
        case darkGlass, lightGlass, textOnly, custom
        var id: Self { self }
        var title: String {
            switch self {
            case .darkGlass: "Dark glass"
            case .lightGlass: "Light glass"
            case .textOnly: "Text only"
            case .custom: "Custom"
            }
        }
    }

    enum FontChoice: String, Codable, CaseIterable, Identifiable {
        case system, rounded, mono, serif
        var id: Self { self }
        var title: String {
            switch self {
            case .system: "SF Pro"
            case .rounded: "SF Rounded"
            case .mono: "SF Mono"
            case .serif: "New York"
            }
        }
        var design: Font.Design {
            switch self {
            case .system: .default
            case .rounded: .rounded
            case .mono: .monospaced
            case .serif: .serif
            }
        }
    }

    enum Weight: String, Codable, CaseIterable, Identifiable {
        case regular, medium, semibold, bold
        var id: Self { self }
        var title: String { rawValue.capitalized }
        var font: Font.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    enum Shape: String, Codable, CaseIterable, Identifiable {
        case capsule, rounded, none
        var id: Self { self }
        var title: String {
            switch self {
            case .capsule: "Capsule"
            case .rounded: "Rounded"
            case .none: "No background"
            }
        }
    }

    enum Content: String, Codable, CaseIterable, Identifiable {
        case icon, number, numberToday
        var id: Self { self }
        var title: String {
            switch self {
            case .icon: "Icon and number"
            case .number: "Number only"
            case .numberToday: "Number and \"today\""
            }
        }
    }

    var isVisible = true
    var preset = Preset.darkGlass
    var fontSize = 20.0
    var font = FontChoice.rounded
    var weight = Weight.semibold
    var text = RGBA(red: 1, green: 1, blue: 1)
    var background = RGBA(red: 0.08, green: 0.08, blue: 0.1)
    var backgroundOpacity = 0.62
    var blur = true
    var shape = Shape.capsule
    var cornerRadius = 10.0
    var content = Content.icon
    var compactNumber = false
    var clickThrough = true
    var fadeOnHover = true
    var hoverOpacity = 0.15
    var overFullScreen = true
    var allDesktops = true
    /// A tiny scale pulse on every key press.
    var pulseOnKey = true
    var pulseScale = 1.02

    mutating func apply(_ preset: Preset) {
        self.preset = preset
        switch preset {
        case .darkGlass:
            text = RGBA(red: 1, green: 1, blue: 1)
            background = RGBA(red: 0.08, green: 0.08, blue: 0.1)
            backgroundOpacity = 0.62
            blur = true
            shape = .capsule
        case .lightGlass:
            text = RGBA(red: 0.1, green: 0.1, blue: 0.12)
            background = RGBA(red: 1, green: 1, blue: 1)
            backgroundOpacity = 0.6
            blur = true
            shape = .capsule
        case .textOnly:
            text = RGBA(red: 1, green: 1, blue: 1)
            backgroundOpacity = 0
            blur = false
            shape = .none
        case .custom:
            break
        }
    }

    private static let key = "widgetStyle"

    static func load() -> WidgetStyle {
        guard let data = UserDefaults.standard.data(forKey: key),
              let style = try? JSONDecoder().decode(WidgetStyle.self, from: data) else { return WidgetStyle() }
        return style
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    var swiftUIFont: Font { .system(size: fontSize, weight: weight.font, design: font.design) }
}

extension WidgetStyle {
    /// Reads saved settings field by field, so settings saved before a new option
    /// existed keep their values instead of resetting to defaults.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let saved = try? c.decodeIfPresent(T.self, forKey: key) { value = saved }
        }
        read(.isVisible, &isVisible)
        read(.preset, &preset)
        read(.fontSize, &fontSize)
        read(.font, &font)
        read(.weight, &weight)
        read(.text, &text)
        read(.background, &background)
        read(.backgroundOpacity, &backgroundOpacity)
        read(.blur, &blur)
        read(.shape, &shape)
        read(.cornerRadius, &cornerRadius)
        read(.content, &content)
        read(.compactNumber, &compactNumber)
        read(.clickThrough, &clickThrough)
        read(.fadeOnHover, &fadeOnHover)
        read(.hoverOpacity, &hoverOpacity)
        read(.overFullScreen, &overFullScreen)
        read(.allDesktops, &allDesktops)
        read(.pulseOnKey, &pulseOnKey)
        read(.pulseScale, &pulseScale)
        if ![1.02, 1.05, 1.07].contains(pulseScale) { pulseScale = 1.02 }
    }
}

struct RGBA: Codable, Equatable {
    var red: Double, green: Double, blue: Double, alpha = 1.0

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
    }
}

/// The capsule that shows today's key count.
struct WidgetView: View {
    @ObservedObject var model: AppModel
    /// True inside Settings, where move mode never shows.
    var isPreview = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let style = model.widget
        let moving = model.isMovingWidget && !isPreview
        content(style, moving: moving)
            .foregroundStyle(style.text.color)
            .lineLimit(1)
            .padding(.horizontal, style.shape == .none ? 6 : style.fontSize * 0.62)
            .padding(.vertical, style.shape == .none ? 3 : style.fontSize * 0.3)
            .modifier(WidgetSurface(style: style, shape: shape(style)))
            .overlay { outline(style, moving: moving) }
            .shadow(color: style.shape == .none ? .black.opacity(0.55) : .clear, radius: 2, y: 1)
            .fixedSize()
            .keyframeAnimator(initialValue: 1.0, trigger: model.today.keys) { pill, scale in
                pill.scaleEffect(scale)
            } keyframes: { _ in
                // Up in 60 ms, settle back in 220 ms: felt more than seen.
                CubicKeyframe(pulsePeak, duration: 0.06)
                SpringKeyframe(1.0, duration: 0.22, spring: .smooth)
            }
            .padding(.horizontal, 3 + pulseRoom(style).width)
            .padding(.vertical, 3 + pulseRoom(style).height)
            .help(model.isCounting ? "\(Format.count(model.today.keys)) keys today" : "Keylog isn't counting yet")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Format.count(model.today.keys)) keys today")
    }

    private func content(_ style: WidgetStyle, moving: Bool) -> some View {
        HStack(spacing: style.fontSize * 0.35) {
            if style.content == .icon || model.isPaused {
                Image(systemName: model.isPaused ? "pause.fill" : "keyboard")
                    .font(.system(size: style.fontSize * 0.72, weight: .medium))
                    .opacity(0.75)
            }
            Text(number)
                .font(style.swiftUIFont)
                .monospacedDigit()
                .opacity(model.isPaused ? 0.6 : 1)
            if style.content == .numberToday {
                Text("today")
                    .font(.system(size: style.fontSize * 0.6, weight: .medium, design: style.font.design))
                    .opacity(0.7)
            }
            if moving {
                Button("Done") { model.isMovingWidget = false }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private func outline(_ style: WidgetStyle, moving: Bool) -> some View {
        if moving {
            shape(style).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        }
    }

    /// Space around the pill so the pulse never gets clipped by the window edge.
    private func pulseRoom(_ style: WidgetStyle) -> CGSize {
        guard style.pulseOnKey else { return .zero }
        let grow = max(0, style.pulseScale - 1) / 2
        return CGSize(width: ceil(style.fontSize * 7 * grow), height: ceil(style.fontSize * 1.8 * grow))
    }

    private var pulsePeak: Double {
        model.widget.pulseOnKey && !reduceMotion && !model.isMovingWidget ? model.widget.pulseScale : 1
    }

    private var number: String {
        guard model.isCounting || isPreview else { return "–" }
        let keys = model.today.keys
        return model.widget.compactNumber ? Format.compact(keys) : Format.count(keys)
    }

    private func shape(_ style: WidgetStyle) -> AnyShape {
        switch style.shape {
        case .capsule: AnyShape(Capsule(style: .continuous))
        case .rounded: AnyShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
        case .none: AnyShape(Rectangle())
        }
    }

}

/// The widget's background: Liquid Glass on macOS 26 under the chosen colour,
/// frosted blur before that, or a plain fill when blur is off.
struct WidgetSurface: ViewModifier {
    let style: WidgetStyle
    let shape: AnyShape

    func body(content: Content) -> some View {
        if style.shape == .none {
            content
        } else if Snapshot.isRendering {
            content.background(style.background.color.opacity(max(style.backgroundOpacity, 0.7)), in: shape)
        } else if #available(macOS 26, *), style.blur {
            // A glass tint alone is too faint: over a white window, white text vanished.
            // The colour layer sits on the glass, so the text always has its contrast.
            content
                .background(style.background.color.opacity(style.backgroundOpacity), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            content.background {
                ZStack {
                    if style.blur { VisualEffectBlur(material: .hudWindow) }
                    style.background.color.opacity(style.backgroundOpacity)
                }
                .clipShape(shape)
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            }
        }
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    /// Rounds the blur itself, so its corners stay clean against the desktop.
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.maskImage = cornerRadius > 0 ? Self.mask(radius: cornerRadius) : nil
    }

    private static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Where the widget sits: a screen corner and the distance in from it.
struct WidgetPlacement: Codable, Equatable {
    enum Corner: String, Codable { case topLeft, topRight, bottomLeft, bottomRight }
    var corner = Corner.topRight
    var dx = 16.0
    var dy = 16.0

    private static let key = "widgetPlacements"

    static func all() -> [String: WidgetPlacement] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let placements = try? JSONDecoder().decode([String: WidgetPlacement].self, from: data) else { return [:] }
        return placements
    }

    static func save(_ placements: [String: WidgetPlacement]) {
        if let data = try? JSONEncoder().encode(placements) { UserDefaults.standard.set(data, forKey: key) }
    }

    func frame(size: CGSize, in area: CGRect) -> CGRect {
        let x: Double, y: Double
        switch corner {
        case .topLeft: (x, y) = (area.minX + dx, area.maxY - dy - size.height)
        case .topRight: (x, y) = (area.maxX - dx - size.width, area.maxY - dy - size.height)
        case .bottomLeft: (x, y) = (area.minX + dx, area.minY + dy)
        case .bottomRight: (x, y) = (area.maxX - dx - size.width, area.minY + dy)
        }
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// The placement for a frame, anchored to its nearest corner; near an edge it snaps to 16 pt.
    static func nearest(to frame: CGRect, in area: CGRect) -> WidgetPlacement {
        let left = frame.midX < area.midX, top = frame.midY > area.midY
        var placement = WidgetPlacement()
        placement.corner = top ? (left ? .topLeft : .topRight) : (left ? .bottomLeft : .bottomRight)
        placement.dx = left ? frame.minX - area.minX : area.maxX - frame.maxX
        placement.dy = top ? area.maxY - frame.maxY : frame.minY - area.minY
        if placement.dx < 40 { placement.dx = 16 }
        if placement.dy < 40 { placement.dy = 16 }
        return placement
    }
}

final class WidgetPanel: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

/// Owns the floating panel: shows it, sizes it, places it, fades it under the pointer.
final class WidgetController {
    private let model: AppModel
    private let panel: WidgetPanel
    private let host: NSHostingView<WidgetView>
    private var placements = WidgetPlacement.all()
    private var subscriptions: Set<AnyCancellable> = []
    private var isUnderPointer = false
    /// Height of the menu bar screen, to flip event-tap coordinates; cached because
    /// it's needed on every mouse move.
    private var primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
    /// ⌃ Control is held: the widget takes clicks even when clicks pass through.
    private var controlHeld = false
    private var clickMonitor: Any?
    var actions = AppActions()

    init(model: AppModel) {
        self.model = model
        panel = WidgetPanel(
            contentRect: CGRect(x: 0, y: 0, width: 120, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        host = NSHostingView(rootView: WidgetView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.onCancel = { [weak model] in model?.isMovingWidget = false }

        // Right-click or ⌃-click opens the menu; a plain click opens the dashboard.
        // Plain clicks only arrive here when "Clicks pass through" is off.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.panel, !self.model.isMovingWidget else { return event }
            if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                NSMenu.popUpContextMenu(KeylogMenu.make(model: self.model, actions: self.actions), with: event, for: self.host)
            } else {
                self.actions.openDashboard(.overview)
            }
            return nil
        }

        model.$widget.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.apply() }
        }.store(in: &subscriptions)
        model.$isMovingWidget.removeDuplicates().sink { [weak self] moving in
            DispatchQueue.main.async { self?.setMoving(moving) }
        }.store(in: &subscriptions)
        // Only a change in the number's length can change the widget's size.
        model.$today.map { $0.keys }.removeDuplicates().map { Format.count($0).count }.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.fit() } }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.rememberPlacement() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
                self?.fit(force: true)
            }
            .store(in: &subscriptions)
    }

    /// Fades the widget when the pointer is over it. `point` is in global
    /// top-left coordinates, straight from the event tap.
    func pointerMoved(to point: CGPoint) {
        let style = model.widget
        guard style.isVisible, style.fadeOnHover, !model.isMovingWidget, panel.isVisible else { return }
        let inside = panel.frame.contains(CGPoint(x: point.x, y: primaryHeight - point.y))
        guard inside != isUnderPointer else { return }
        isUnderPointer = inside
        let target = inside && !controlHeld ? style.hoverOpacity : 1
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = target
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = target
            }
        }
    }

    /// Called when ⌃ Control goes down or up anywhere.
    func controlChanged(held: Bool) {
        guard held != controlHeld else { return }
        controlHeld = held
        updateMouseHandling()
        if isUnderPointer { panel.alphaValue = held ? 1 : model.widget.hoverOpacity }
    }

    private func updateMouseHandling() {
        panel.ignoresMouseEvents = model.widget.clickThrough && !model.isMovingWidget && !controlHeld
    }

    private func apply() {
        let style = model.widget
        guard style.isVisible else {
            panel.orderOut(nil)
            return
        }
        var behavior: NSWindow.CollectionBehavior = [.ignoresCycle, .stationary]
        behavior.insert(style.allDesktops ? .canJoinAllSpaces : .moveToActiveSpace)
        if style.overFullScreen { behavior.insert(.fullScreenAuxiliary) }
        panel.collectionBehavior = behavior
        updateMouseHandling()
        if !style.fadeOnHover {
            isUnderPointer = false
            panel.alphaValue = 1
        }
        fit(force: true)
        panel.orderFrontRegardless()
    }

    private func setMoving(_ moving: Bool) {
        panel.isMovableByWindowBackground = moving
        updateMouseHandling()
        panel.alphaValue = 1
        isUnderPointer = false
        if moving {
            panel.makeKey()
        } else {
            rememberPlacement(snap: true)
            panel.resignKey()
        }
        fit(force: true)
    }

    /// The screen the widget is on. Nil only for a moment while displays change.
    private var screen: NSScreen? {
        panel.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func screenID(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "main"
    }

    /// Sizes the panel to its content, keeping it pinned to its corner.
    private func fit(force: Bool = false) {
        guard model.widget.isVisible else { return }
        let size = host.fittingSize
        guard force || size != panel.frame.size, let screen else { return }
        let placement = placements[screenID(screen)] ?? WidgetPlacement()
        let frame = placement.frame(size: size, in: screen.visibleFrame)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    private func rememberPlacement(snap: Bool = false) {
        guard model.isMovingWidget || snap, let screen else { return }
        placements[screenID(screen)] = WidgetPlacement.nearest(to: panel.frame, in: screen.visibleFrame)
        WidgetPlacement.save(placements)
        if snap { fit(force: true) }
    }

    func resetPosition() {
        placements = [:]
        WidgetPlacement.save(placements)
        fit(force: true)
    }
}
