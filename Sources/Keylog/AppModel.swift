import AppKit
import KeylogCore
import SwiftUI

/// Live state shared by the popover, the widget, the dashboard and Settings.
/// Recorder changes are coalesced, so fast typing redraws at most 20 times a second.
final class AppModel: ObservableObject {
    @Published private(set) var today = Counts()
    @Published private(set) var todayKeys: [UInt16: Int] = [:]
    @Published private(set) var isCounting = false
    @Published var isPaused = Preferences.isPaused {
        didSet {
            Preferences.isPaused = isPaused
            onPauseChange(isPaused)
        }
    }
    @Published var menuBarDisplay = Preferences.menuBarDisplay {
        didSet { Preferences.menuBarDisplay = menuBarDisplay }
    }
    @Published var weekStart = Preferences.weekStart {
        didSet { Preferences.weekStart = weekStart }
    }
    @Published var tracksApps = Preferences.tracksApps {
        didSet {
            Preferences.tracksApps = tracksApps
            recorder.tracksApps = tracksApps
        }
    }
    @Published var tracksMouse = Preferences.tracksMouse {
        didSet {
            Preferences.tracksMouse = tracksMouse
            onTrackMouseChange(tracksMouse)
        }
    }
    @Published var widget = WidgetStyle.load() {
        didSet { if !Snapshot.isRendering { widget.save() } }
    }
    @Published var isMovingWidget = false
    /// Typing speed right now, in keys per minute; refreshed every second.
    @Published private(set) var liveKPM = 0
    @Published var tintBySpeed = Preferences.tintBySpeed {
        didSet { Preferences.tintBySpeed = tintBySpeed }
    }
    @Published var keyMilestone = Preferences.keyMilestone {
        didSet {
            Preferences.keyMilestone = keyMilestone
            if keyMilestone > 0 { Milestones.requestPermission() }
        }
    }
    @Published var clickMilestone = Preferences.clickMilestone {
        didSet {
            Preferences.clickMilestone = clickMilestone
            if clickMilestone > 0 { Milestones.requestPermission() }
        }
    }
    /// Every keyboard type seen, and whether its keys count.
    @Published var keyboards = Preferences.keyboards {
        didSet {
            Preferences.keyboards = keyboards
            onKeyboardsChange(ignoredKeyboards)
        }
    }
    /// Bumped when stored data changes outside normal counting (delete all).
    @Published private(set) var dataVersion = 0

    let store: Store
    let recorder: Recorder
    var onPauseChange: (Bool) -> Void = { _ in }
    var onTrackMouseChange: (Bool) -> Void = { _ in }
    var onKeyboardsChange: (Set<Int>) -> Void = { _ in }

    var ignoredKeyboards: Set<Int> { Set(keyboards.filter { !$0.counts }.map(\.type)) }

    /// Adds a keyboard type the first time it sends a key.
    func keyboardSeen(_ type: Int) {
        guard !keyboards.contains(where: { $0.type == type }) else { return }
        keyboards.append(KeyboardSource(type: type, counts: !KeyboardSource.virtualTypes.contains(type)))
        keyboards.sort { $0.type > $1.type }
    }
    private var updateScheduled = false
    private var liveTimer: Timer?
    private let milestones = Milestones()
    private var lastPublish = Date.distantPast

    init(store: Store, recorder: Recorder) {
        self.store = store
        self.recorder = recorder
        refreshFirstDay()
        publish()
    }

    /// Gregorian days in the Mac's time zone, weeks starting where the user wants.
    var calendar: Calendar {
        var calendar = recorder.clock.calendar
        calendar.firstWeekday = weekStart.firstWeekday
        return calendar
    }

    var clock: DayClock { recorder.clock }

    func setCounting(_ counting: Bool) {
        isCounting = counting
    }

    /// Called on every recorder change; publishes at most every 50 ms.
    func recorderChanged() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.updateScheduled = false
            self?.publish()
        }
    }

    /// Mouse travel alone changes counts on every movement; publish that at most
    /// every two seconds, and key or click changes straight away.
    func publish() {
        let latest = recorder.today
        let now = Date()
        if latest.keys != today.keys || latest.clicks != today.clicks || latest.isEmpty != today.isEmpty
            || (latest != today && now.timeIntervalSince(lastPublish) >= 2) {
            today = latest
            lastPublish = now
        }
        if todayKeys != recorder.todayKeys { todayKeys = recorder.todayKeys }
        if !Snapshot.isRendering {
            let top = todayKeys.max { $0.value < $1.value }.map { KeyNames.name($0.key) }
            milestones.check(latest, day: recorder.currentDay, keyStep: keyMilestone, clickStep: clickMilestone, topKey: top)
        }
    }

    /// Refreshes the live typing speed once a second.
    func startLiveUpdates() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let speed = recorder.liveKeysPerMinute()
            if speed != liveKPM { liveKPM = speed }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    /// Stats for a period, including counts not yet written to disk.
    func stats(for period: Period) -> PeriodStats {
        recorder.flush(wait: true)
        return store.stats(for: period, clock: clock)
    }

    func keyCounts(for period: Period, app: String?) -> [UInt16: Int] {
        recorder.flush(wait: true)
        let days = period.days(clock: clock)
        return store.keyCounts(from: days.first, through: days.last, app: app)
    }

    func apps(for period: Period) -> [String: AppUse] {
        recorder.flush(wait: true)
        let days = period.days(clock: clock)
        return store.apps(from: days.first, through: days.last)
    }

    /// The first day anything was recorded. Cached: views read it on every redraw.
    private(set) var firstDay: Date?

    /// Re-reads the first day; cheap, and only needed until something is recorded.
    func refreshFirstDay() {
        guard let day = store.firstDay() else {
            firstDay = nil
            return
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        firstDay = formatter.date(from: day)
    }

    func period(_ kind: PeriodKind, containing date: Date = Date()) -> Period {
        .containing(date, kind: kind, calendar: calendar, firstDay: kind == .all ? firstDay : nil)
    }

    /// The last `days` days, ending today.
    func recentDays(_ days: Int) -> Period {
        let calendar = calendar
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let start = calendar.date(byAdding: .day, value: -days, to: end)!
        return Period(kind: days <= 7 ? .week : .month, start: start, end: end)
    }

    func deleteAllData() {
        store.deleteAll()
        dataChanged()
    }

    /// Starts today again from zero. Earlier days are kept.
    func resetToday() {
        recorder.flush(wait: true)
        store.deleteDay(recorder.currentDay)
        dataChanged()
    }

    func importBackup(_ data: Data, replace: Bool) throws {
        recorder.flush(wait: true)
        try store.importBackup(data, replace: replace)
        dataChanged()
    }

    /// Reloads everything after the stored data changed underneath.
    private func dataChanged() {
        recorder.reset()
        refreshFirstDay()
        publish()
        dataVersion += 1
    }
}

/// A keyboard as macOS reports it: by type, not by name.
struct KeyboardSource: Codable, Equatable, Identifiable {
    /// Type 3 is an old Apple keyboard no Mac uses today; virtual keyboards, such as
    /// the one USB Overdrive uses to turn mouse buttons into shortcuts, report it.
    static let virtualTypes: Set<Int> = [3]

    let type: Int
    var counts: Bool
    var id: Int { type }

    var name: String {
        KeyboardSource.virtualTypes.contains(type) ? "Virtual keyboard (mouse button shortcuts)" : "Keyboard, type \(type)"
    }
}

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case icon, keys, keysAndClicks
    var id: Self { self }
    var title: String {
        switch self {
        case .icon: "Icon only"
        case .keys: "Icon and today's keys"
        case .keysAndClicks: "Icon, keys and clicks"
        }
    }
}

enum WeekStart: String, CaseIterable, Identifiable {
    case system, monday, sunday
    var id: Self { self }
    var title: String {
        switch self {
        case .system: "Mac's setting"
        case .monday: "Monday"
        case .sunday: "Sunday"
        }
    }
    var firstWeekday: Int {
        switch self {
        case .system: Calendar.current.firstWeekday
        case .monday: 2
        case .sunday: 1
        }
    }
}

/// Settings kept in the app's preferences.
enum Preferences {
    private static let defaults = UserDefaults.standard

    static var isPaused: Bool {
        get { defaults.bool(forKey: "paused") }
        set { defaults.set(newValue, forKey: "paused") }
    }

    static var tracksApps: Bool {
        get { defaults.object(forKey: "tracksApps") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "tracksApps") }
    }

    static var tracksMouse: Bool {
        get { defaults.object(forKey: "tracksMouse") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "tracksMouse") }
    }

    static var menuBarDisplay: MenuBarDisplay {
        get { defaults.string(forKey: "menuBarDisplay").flatMap(MenuBarDisplay.init) ?? .keys }
        set { defaults.set(newValue.rawValue, forKey: "menuBarDisplay") }
    }

    /// Starts with the virtual keyboard switched off.
    static var keyboards: [KeyboardSource] {
        get {
            guard let data = defaults.data(forKey: "keyboards"),
                  let list = try? JSONDecoder().decode([KeyboardSource].self, from: data) else {
                return KeyboardSource.virtualTypes.map { KeyboardSource(type: $0, counts: false) }
            }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "keyboards") }
        }
    }

    static var tintBySpeed: Bool {
        get { defaults.bool(forKey: "tintBySpeed") }
        set { defaults.set(newValue, forKey: "tintBySpeed") }
    }

    /// Keys between milestone notifications; 0 is off.
    static var keyMilestone: Int {
        get { defaults.object(forKey: "keyMilestone") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "keyMilestone") }
    }

    static var clickMilestone: Int {
        get { defaults.object(forKey: "clickMilestone") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "clickMilestone") }
    }

    static var weekStart: WeekStart {
        get { defaults.string(forKey: "weekStart").flatMap(WeekStart.init) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "weekStart") }
    }
}
