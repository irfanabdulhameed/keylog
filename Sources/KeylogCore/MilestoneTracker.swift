/// Decides when today's keys or clicks pass a milestone, such as every 10,000 keys.
/// Pure and side-effect free, so it can be tested; the app posts the notifications.
public struct MilestoneTracker: Codable, Equatable, Sendable {
    public private(set) var day: String?
    /// Counts at the last milestone, or when counting started.
    public private(set) var keys = 0
    public private(set) var clicks = 0

    public init() {}

    /// The milestones passed since the last check, if any. A new day starts from the
    /// counts already there, so nothing fires for milestones passed before.
    public mutating func check(keys: Int, clicks: Int, day: String, keyStep: Int, clickStep: Int)
        -> (keys: Int?, clicks: Int?)
    {
        guard day == self.day else {
            rebase(keys: keys, clicks: clicks, day: day)
            return (nil, nil)
        }
        var passed: (keys: Int?, clicks: Int?) = (nil, nil)
        if keyStep > 0, keys / keyStep > self.keys / keyStep {
            passed.keys = keys / keyStep * keyStep
            self.keys = keys
        }
        if clickStep > 0, clicks / clickStep > self.clicks / clickStep {
            passed.clicks = clicks / clickStep * clickStep
            self.clicks = clicks
        }
        return passed
    }

    /// Counts milestones from here, for when a milestone setting changes.
    public mutating func rebase(keys: Int, clicks: Int, day: String) {
        self.day = day
        self.keys = keys
        self.clicks = clicks
    }
}
