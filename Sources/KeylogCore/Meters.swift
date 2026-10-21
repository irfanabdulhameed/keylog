import CoreGraphics

/// Keys pressed in the trailing one-second window, on a monotonic clock so changing
/// the Mac's time can't fake a burst.
public struct SpeedMeter: Sendable {
    private var times: [Double] = []
    private var head = 0

    public init() {}

    /// Records a key press at `uptime` seconds and returns the keys in the last second.
    public mutating func tick(at uptime: Double) -> Int {
        times.append(uptime)
        while head < times.count, times[head] <= uptime - 1 { head += 1 }
        if head > 64 {
            times.removeFirst(head)
            head = 0
        }
        return times.count - head
    }
}

/// A display's bounds in global screen points and its physical size per point.
public struct DisplayScale: Sendable {
    public let bounds: CGRect
    public let mmPerPoint: Double

    public init(bounds: CGRect, mmPerPoint: Double) {
        self.bounds = bounds
        self.mmPerPoint = mmPerPoint
    }

    /// The active displays, measured from the sizes they report.
    public static func current() -> [DisplayScale] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            let widthMM = CGDisplayScreenSize(id).width
            let scale = widthMM > 0 && bounds.width > 0
                ? Double(widthMM / bounds.width) : MouseMeter.fallbackMMPerPoint
            return DisplayScale(bounds: bounds, mmPerPoint: scale)
        }
    }
}

/// Turns pointer movement in screen points into real distance.
public struct MouseMeter: Sendable {
    /// Used when a display doesn't report its size: a 96 dpi screen.
    public static let fallbackMMPerPoint = 25.4 / 96
    /// A single step longer than this is the pointer warping, not the hand moving.
    public static let jumpLimit = 500.0

    public var displays: [DisplayScale]
    private var last: CGPoint?

    public init(displays: [DisplayScale]) {
        self.displays = displays
    }

    /// Forgets the last position, so the next move starts fresh instead of jumping.
    public mutating func reset() { last = nil }

    /// Returns the millimetres travelled moving to `point`.
    public mutating func move(to point: CGPoint) -> Double {
        defer { last = point }
        guard let last else { return 0 }
        let distance = hypot(point.x - last.x, point.y - last.y)
        guard distance <= Self.jumpLimit else { return 0 }
        return distance * scale(at: point)
    }

    /// Millimetres for a scroll of `dx` by `dy` points at the pointer's display.
    public func scroll(dx: Double, dy: Double) -> Double {
        hypot(dx, dy) * scale(at: last ?? .zero)
    }

    func scale(at point: CGPoint) -> Double {
        displays.first { $0.bounds.contains(point) }?.mmPerPoint
            ?? displays.first?.mmPerPoint ?? Self.fallbackMMPerPoint
    }
}
