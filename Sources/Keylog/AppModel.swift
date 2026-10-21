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
    /// Bumped when stored data changes outside normal counting (delete all).
    @Published private(set) var dataVersion = 0

    let store: Store
    let recorder: Recorder
    var onPauseChange: (Bool) -> Void = { _ in }
    var onTrackMouseChange: (Bool) -> Void = { _ in }
    private var updateScheduled = false
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
        recorder.reset()
        refreshFirstDay()
        publish()
        dataVersion += 1
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

    static var weekStart: WeekStart {
        get { defaults.string(forKey: "weekStart").flatMap(WeekStart.init) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "weekStart") }
    }
}
