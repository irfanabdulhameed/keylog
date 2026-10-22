import CoreGraphics
import Foundation

/// Raw input as the event tap reports it, before any counting rules.
public enum InputEvent: Equatable, Sendable {
    /// `character` is what the key types on the current layout; it is never stored.
    case key(code: UInt16, character: Character?, isRepeat: Bool)
    /// `flags` are the raw event flags, when known, so a missed release can't leave
    /// a modifier stuck down.
    case modifier(code: UInt16, isDown: Bool, flags: UInt64? = nil)
    case capsLock
    case click(MouseButton)
    case move(CGPoint)
    case scroll(dx: Double, dy: Double, isMomentum: Bool)
}

/// Applies the counting rules and passes the results to the recorder:
/// - a held key counts once;
/// - a modifier counts only when tapped on its own, never as part of a shortcut,
///   though every modifier press still shows on the heatmap;
/// - mouse travel ignores warps, scrolling ignores momentum after the fingers lift.
public final class InputProcessor {
    public var isPaused = false {
        didSet { resetState() }
    }
    public var tracksMouse = true {
        didSet { mouse.reset() }
    }

    private let recorder: Recorder
    private var mouse: MouseMeter
    private var heldModifiers: Set<UInt16> = []
    /// The modifier that will count as a tap if it is released before anything else happens.
    private var pendingTap: UInt16?

    public init(recorder: Recorder, displays: [DisplayScale]) {
        self.recorder = recorder
        mouse = MouseMeter(displays: displays)
    }

    public func updateDisplays(_ displays: [DisplayScale]) {
        mouse.displays = displays
        mouse.reset()
    }

    /// Call after sleep, so the first move doesn't count as travel from before.
    public func resetState() {
        mouse.reset()
        heldModifiers = []
        pendingTap = nil
    }

    public func handle(_ event: InputEvent, at date: Date, uptime: Double) {
        guard !isPaused else { return }
        switch event {
        case let .key(code, character, isRepeat):
            guard !isRepeat else { return }
            pendingTap = nil
            let group = KeyClassifier.group(keyCode: code, character: character)
            recorder.recordKey(group, code: code, at: date, uptime: uptime)

        case let .modifier(code, isDown, flags):
            if let flags {
                heldModifiers = heldModifiers.filter { $0 == code || ModifierKey.isDown(code: $0, flags: flags) }
            }
            if isDown {
                guard !heldModifiers.contains(code) else { return }
                pendingTap = heldModifiers.isEmpty ? code : nil
                heldModifiers.insert(code)
                recorder.recordKeyUse(code: code, at: date)
            } else {
                heldModifiers.remove(code)
                if pendingTap == code {
                    pendingTap = nil
                    recorder.recordKey(.other, code: code, at: date, uptime: uptime, onHeatmap: false)
                }
            }

        case .capsLock:
            pendingTap = nil
            recorder.recordKey(.other, code: ModifierKey.capsLock, at: date, uptime: uptime)

        case let .click(button):
            pendingTap = nil
            // Only real clicks: side and wheel buttons are for navigating, not clicking.
            guard button == .left || button == .right else { return }
            recorder.recordClick(button, at: date, uptime: uptime)

        case let .move(point):
            guard tracksMouse else { return }
            let mm = mouse.move(to: point)
            if mm > 0 { recorder.recordMouse(mm: mm, at: date) }

        case let .scroll(dx, dy, isMomentum):
            pendingTap = nil  // ⇧-scroll and ⌘-scroll are shortcuts, not taps
            guard tracksMouse, !isMomentum else { return }
            let mm = mouse.scroll(dx: dx, dy: dy)
            if mm > 0 { recorder.recordScroll(mm: mm, at: date) }
        }
    }
}
