import Foundation

public enum PeriodKind: Int, CaseIterable, Sendable {
    case day, week, month, year, all
}

/// A span of whole local days the dashboard shows, and how its chart is split.
public struct Period: Equatable, Sendable {
    public enum Unit: Sendable { case hour, day, month }

    public let kind: PeriodKind
    /// Start of the first day.
    public let start: Date
    /// Start of the day after the last one.
    public let end: Date

    public init(kind: PeriodKind, start: Date, end: Date) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    /// The period of `kind` that contains `date`. "All time" runs from `firstDay` to today.
    public static func containing(
        _ date: Date, kind: PeriodKind, calendar: Calendar, firstDay: Date? = nil, now: Date = Date()
    ) -> Period {
        let component: Calendar.Component
        switch kind {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        case .all:
            let first = calendar.startOfDay(for: min(firstDay ?? now, now))
            let afterToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            return Period(kind: .all, start: first, end: afterToday)
        }
        let interval = calendar.dateInterval(of: component, for: date)!
        return Period(kind: kind, start: interval.start, end: interval.end)
    }

    /// The period `steps` before (negative) or after (positive) this one.
    public func shifted(by steps: Int, calendar: Calendar) -> Period {
        guard kind != .all, steps != 0 else { return self }
        let component: Calendar.Component = [.day: .day, .week: .weekOfYear, .month: .month, .year: .year][kind]!
        let moved = calendar.date(byAdding: component, value: steps, to: start)!
        return .containing(moved, kind: kind, calendar: calendar)
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    public var unit: Unit {
        switch kind {
        case .day: .hour
        case .week, .month: .day
        case .year, .all: .month
        }
    }

    /// Number of days in the period, for daily averages.
    public func dayCount(calendar: Calendar) -> Int {
        max(1, calendar.dateComponents([.day], from: start, to: end).day ?? 1)
    }

    /// First and last day as stored ("yyyy-MM-dd").
    public func days(clock: DayClock) -> (first: String, last: String) {
        (clock.day(for: start), clock.day(for: end.addingTimeInterval(-1)))
    }

    /// One slot per chart bar: hours of a day, days of a week or month, or months.
    public func slots(clock: DayClock) -> [ChartSlot] {
        let calendar = clock.calendar
        var slots: [ChartSlot] = []
        var cursor = start
        let step: Calendar.Component = [.hour: .hour, .day: .day, .month: .month][unit]!
        if unit == .month { cursor = calendar.dateInterval(of: .month, for: start)!.start }
        while cursor < end {
            let key: String
            switch unit {
            case .hour: key = String(calendar.component(.hour, from: cursor))
            case .day: key = clock.day(for: cursor)
            case .month: key = String(clock.day(for: cursor).prefix(7))
            }
            // Daylight saving can repeat an hour; keep one bar per hour number.
            if slots.last?.key != key { slots.append(ChartSlot(index: slots.count, start: cursor, key: key)) }
            cursor = calendar.date(byAdding: step, value: 1, to: cursor)!
        }
        return slots
    }
}

public struct ChartSlot: Identifiable, Equatable, Sendable {
    public let index: Int
    public let start: Date
    /// Hour number, "yyyy-MM-dd" or "yyyy-MM", matching how rows are grouped.
    public let key: String
    public var id: Int { index }
}

/// Everything the dashboard needs for one period.
public struct PeriodStats: Sendable {
    public var period: Period
    public var total = Counts()
    public var slots: [ChartSlot] = []
    public var slotCounts: [Counts] = []
    /// Days with at least one key or click.
    public var activeDays = 0
    public var dailyTotals: [String: Counts] = [:]

    public init(period: Period) { self.period = period }
}

extension Store {
    public func stats(for period: Period, clock: DayClock) -> PeriodStats {
        var stats = PeriodStats(period: period)
        let days = period.days(clock: clock)
        let rows = hours(from: days.first, through: days.last)
        stats.slots = period.slots(clock: clock)
        var bySlot: [String: Counts] = [:]
        for row in rows {
            stats.total.add(row.counts)
            stats.dailyTotals[row.day, default: Counts()].add(row.counts)
            let key: String
            switch period.unit {
            case .hour: key = String(row.hour)
            case .day: key = row.day
            case .month: key = String(row.day.prefix(7))
            }
            bySlot[key, default: Counts()].add(row.counts)
        }
        stats.slotCounts = stats.slots.map { bySlot[$0.key] ?? Counts() }
        stats.activeDays = stats.dailyTotals.values.filter { $0.keys + $0.clicks > 0 }.count
        return stats
    }
}
