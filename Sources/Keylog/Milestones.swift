import Foundation
import KeylogCore
import UserNotifications

/// Posts a notification each time today's keys or clicks pass a milestone, like
/// every 10,000 keys. Never for milestones passed before Keylog was watching.
final class Milestones {
    private let defaults = UserDefaults.standard
    private var day: String?
    private var lastKeys = 0
    private var lastClicks = 0

    init() {
        day = defaults.string(forKey: "milestoneDay")
        lastKeys = defaults.integer(forKey: "milestoneKeys")
        lastClicks = defaults.integer(forKey: "milestoneClicks")
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func check(_ today: Counts, day: String, keyStep: Int, clickStep: Int, topKey: String?) {
        if day != self.day {
            // A new day, or the first run: start from what's already counted.
            self.day = day
            lastKeys = today.keys
            lastClicks = today.clicks
            save()
            return
        }
        if crossed(today.keys, since: &lastKeys, step: keyStep) {
            let speed = today.activeMinutes > 0 ? "\(Int(today.keysPerActiveMinute.rounded())) keys a minute while typing" : nil
            let top = topKey.map { "busiest key: \($0)" }
            post("\(Format.count(today.keys / keyStep * keyStep)) keys today",
                 body: [speed, top].compactMap { $0 }.joined(separator: ", ").capitalizedFirst)
        }
        if crossed(today.clicks, since: &lastClicks, step: clickStep) {
            post("\(Format.count(today.clicks / clickStep * clickStep)) clicks today",
                 body: "Left \(Format.count(today.clicksLeft)), right \(Format.count(today.clicksRight)).")
        }
    }

    /// Whether `value` passed a multiple of `step` since the last check. While a
    /// milestone is off, the baseline follows along, so turning it on doesn't fire.
    private func crossed(_ value: Int, since last: inout Int, step: Int) -> Bool {
        guard step > 0 else {
            if last != value { last = value; save() }
            return false
        }
        guard value / step > last / step else { return false }
        last = value
        save()
        return true
    }

    private func save() {
        defaults.set(day, forKey: "milestoneDay")
        defaults.set(lastKeys, forKey: "milestoneKeys")
        defaults.set(lastClicks, forKey: "milestoneClicks")
    }

    private func post(_ title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
