import Foundation

/// One hour of one local day: the unit everything is stored in.
public struct HourBucket: Equatable, Sendable {
    /// Local date as "yyyy-MM-dd".
    public let day: String
    public let hour: Int
    /// Time zone the hour was recorded in, so travel never reshuffles past hours.
    public let timeZone: String
    public let start: Date
    public let end: Date

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// Minute of the hour (0–59) a moment falls in.
    public func minute(of date: Date) -> Int {
        min(59, max(0, Int(date.timeIntervalSince(start) / 60)))
    }
}

/// Maps moments to local days and hours. Days always use the Gregorian calendar so
/// stored dates stay comparable whatever calendar the Mac is set to.
public struct DayClock: Sendable {
    public let calendar: Calendar

    public init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    public func bucket(for date: Date) -> HourBucket {
        let interval = calendar.dateInterval(of: .hour, for: date)!
        let hour = calendar.component(.hour, from: date)
        return HourBucket(
            day: day(for: date), hour: hour, timeZone: calendar.timeZone.identifier,
            start: interval.start, end: interval.end)
    }

    public func day(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}
