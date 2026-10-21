import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Listens to keyboard and mouse input system-wide. The tap is listen-only: it can
/// never change, block or delay input. It needs the Input Monitoring permission.
/// Password fields are hidden from it by macOS ("secure input").
public final class EventTap {
    /// The event, its wall-clock time and seconds since the Mac started (monotonic).
    public var onEvent: ((InputEvent, Date, Double) -> Void)?
    /// Called when macOS had switched the tap off, so events may have been missed.
    public var onResume: (() -> Void)?
    /// Keyboard types whose keys aren't counted.
    public var ignoredKeyboards: Set<Int> = []
    /// Called the first time a keyboard type sends a key in this session.
    public var onKeyboardSeen: ((Int) -> Void)?
    private var seenKeyboards: Set<Int> = []

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let translator = KeyTranslator()

    public init() {}

    public static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt and adds Keylog to the Input Monitoring list.
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestListenEventAccess() }

    public var isRunning: Bool { tap != nil }

    /// Starts listening on the main run loop. Returns false without permission.
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .keyDown || type == .flagsChanged {
            // Each keyboard reports a type; skip keyboards the user turned off, such as
            // the virtual keyboard mouse tools use to turn side buttons into shortcuts.
            let keyboard = Int(event.getIntegerValueField(.keyboardEventKeyboardType))
            if !seenKeyboards.contains(keyboard) {
                seenKeyboards.insert(keyboard)
                onKeyboardSeen?(keyboard)
            }
            if ignoredKeyboards.contains(keyboard) { return }
        }
        let input: InputEvent
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switches slow taps off; switch straight back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            onResume?()
            return
        case .keyDown:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let character = isRepeat ? nil : translator.character(for: code, flags: event.flags)
            input = .key(code: code, character: character, isRepeat: isRepeat)
        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if code == ModifierKey.capsLock {
                input = .capsLock
            } else if ModifierKey.isModifier(code) {
                let flags = event.flags.rawValue
                input = .modifier(code: code, isDown: ModifierKey.isDown(code: code, flags: flags), flags: flags)
            } else {
                return
            }
        case .leftMouseDown:
            input = .click(.left)
        case .rightMouseDown:
            input = .click(.right)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            input = .move(event.location)
        case .scrollWheel:
            input = .scroll(
                dx: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                dy: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
                isMomentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0)
        default:
            return
        }
        onEvent?(input, Date(), ProcessInfo.processInfo.systemUptime)
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}

/// Works out which character a key types on the current keyboard layout, with
/// Shift, Option and Caps Lock applied and ⌘/⌃ ignored, so ⌘C still reads as "c".
public final class KeyTranslator {
    private var layout: CFData?
    private var observer: NSObjectProtocol?

    public init() {
        reload()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }

    private func reload() {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            layout = nil
            return
        }
        layout = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue()
    }

    public func character(for code: UInt16, flags: CGEventFlags = []) -> Character? {
        guard let layout, let bytes = CFDataGetBytePtr(layout) else { return nil }
        var modifiers = 0
        if flags.contains(.maskShift) { modifiers |= shiftKey }
        if flags.contains(.maskAlphaShift) { modifiers |= alphaLock }
        if flags.contains(.maskAlternate) { modifiers |= optionKey }
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self),
            code, UInt16(kUCKeyActionDown), UInt32((modifiers >> 8) & 0xFF), UInt32(LMGetKbdType()),
            OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).first
    }
}

