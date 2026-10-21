import Foundation

/// Gathers counts in memory, keeps today's running totals, and hands each hour's
/// counts to the store when asked to flush. Use from the main thread only.
public final class Recorder {
    public private(set) var today = Counts()
    /// Presses per physical key today, across all apps.
    public private(set) var todayKeys: [UInt16: Int] = [:]
    public private(set) var clock: DayClock
    public var tracksApps = true
    /// The app in front: bundle id and display name.
    public var currentApp: () -> (id: String, name: String) = { ("", "") }
    /// Called after every change; UI should coalesce these.
    public var onChange: (() -> Void)?

    private let store: Store
    private var bucket: HourBucket
    private var pending: HourFlush
    /// Every minute typed in this hour, including minutes already written.
    private var hourMask: UInt64 = 0
    private var hourPeak = 0
    private var speed = SpeedMeter()

    public init(store: Store, clock: DayClock = DayClock(), now: Date = Date()) {
        self.store = store
        self.clock = clock
        bucket = clock.bucket(for: now)
        pending = HourFlush(bucket: bucket)
        load()
    }

    public var currentDay: String { bucket.day }

    /// Moves on to a new hour or day if `date` has left the current one.
    public func tick(_ date: Date = Date()) {
        roll(to: date)
    }

    /// Switches time zone, for when the Mac's zone changes.
    public func setClock(_ clock: DayClock, now: Date = Date()) {
        flush()
        self.clock = clock
        bucket = clock.bucket(for: now)
        pending = HourFlush(bucket: bucket)
        load()
        onChange?()
    }

    /// Forgets everything, after the store has been emptied.
    public func reset(now: Date = Date()) {
        pending = HourFlush(bucket: bucket)
        roll(to: now)
        load()
        onChange?()
    }

    /// Writes everything gathered so far. `wait` blocks until it is on disk.
    public func flush(wait: Bool = false) {
        if !pending.isEmpty {
            store.write(pending, wait: wait)
            pending = HourFlush(bucket: bucket)
        } else if wait {
            store.sync()
        }
    }

    // MARK: Recording

    public func recordKey(
        _ group: KeyGroup, code: UInt16, at date: Date, uptime: Double, onHeatmap: Bool = true
    ) {
        roll(to: date)
        pending.counts[group] += 1
        today[group] += 1
        let app = frontApp()
        if onHeatmap {
            pending.keys[KeyUse(app: app?.id ?? "", key: code), default: 0] += 1
            todayKeys[code, default: 0] += 1
        }
        update(app) { $0.keys += 1 }

        let bit: UInt64 = 1 << UInt64(bucket.minute(of: date))
        pending.minutesMask |= bit
        if hourMask & bit == 0 {
            hourMask |= bit
            today.activeMinutes += 1
        }
        let lastSecond = speed.tick(at: uptime)
        if lastSecond > hourPeak {
            hourPeak = lastSecond
            pending.counts.peakKPS = lastSecond
        }
        today.peakKPS = max(today.peakKPS, lastSecond)
        onChange?()
    }

    /// A press that shows on the heatmap but isn't counted: a modifier held for a shortcut.
    public func recordKeyUse(code: UInt16, at date: Date) {
        roll(to: date)
        pending.keys[KeyUse(app: frontApp()?.id ?? "", key: code), default: 0] += 1
        todayKeys[code, default: 0] += 1
    }

    public func recordClick(_ button: MouseButton, at date: Date) {
        roll(to: date)
        pending.counts[button] += 1
        today[button] += 1
        update(frontApp()) { $0.clicks += 1 }
        onChange?()
    }

    public func recordMouse(mm: Double, at date: Date) {
        roll(to: date)
        pending.counts.mouseMM += mm
        today.mouseMM += mm
        onChange?()
    }

    public func recordScroll(mm: Double, at date: Date) {
        roll(to: date)
        pending.counts.scrollMM += mm
        today.scrollMM += mm
        update(frontApp()) { $0.scrollMM += mm }
        onChange?()
    }

    // MARK: Private

    private func roll(to date: Date) {
        guard !bucket.contains(date) else { return }
        flush()
        bucket = clock.bucket(for: date)
        pending = HourFlush(bucket: bucket)
        load()
        onChange?()
    }

    /// Reloads today's totals and this hour's state from the store.
    private func load() {
        let rows = store.hours(from: bucket.day, through: bucket.day)
        today = rows.reduce(into: Counts()) { $0.add($1.counts) }
        todayKeys = store.keyCounts(from: bucket.day, through: bucket.day)
        let hour = rows.first { $0.hour == bucket.hour }
        hourMask = hour?.minutesMask ?? 0
        hourPeak = hour?.counts.peakKPS ?? 0
    }

    private func frontApp() -> (id: String, name: String)? {
        guard tracksApps else { return nil }
        let app = currentApp()
        return app.id.isEmpty ? nil : app
    }

    private func update(_ app: (id: String, name: String)?, _ change: (inout AppUse) -> Void) {
        guard let app else { return }
        var use = pending.apps[app.id] ?? AppUse(name: app.name)
        use.name = app.name
        change(&use)
        pending.apps[app.id] = use
    }
}
