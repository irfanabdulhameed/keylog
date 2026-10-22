import Foundation
import KeylogCore
import UserNotifications

/// Posts a notification each time today's keys or clicks pass a milestone.
final class Milestones {
    private static let key = "milestones"
    private var tracker: MilestoneTracker

    init() {
        tracker = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(MilestoneTracker.self, from: $0) } ?? MilestoneTracker()
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func check(_ today: Counts, day: String, keyStep: Int, clickStep: Int, topKey: String?) {
        let before = tracker
        let passed = tracker.check(keys: today.keys, clicks: today.clicks, day: day, keyStep: keyStep, clickStep: clickStep)
        if tracker != before { save() }
        if let keys = passed.keys {
            let speed = today.activeMinutes > 0 ? "\(Int(today.keysPerActiveMinute.rounded())) keys a minute while typing" : nil
            let top = topKey.map { "busiest key: \($0)" }
            post("\(Format.count(keys)) keys today", body: [speed, top].compactMap { $0 }.joined(separator: ", ").capitalizedFirst)
        }
        if let clicks = passed.clicks {
            post("\(Format.count(clicks)) clicks today",
                 body: "Left \(Format.count(today.clicksLeft)), right \(Format.count(today.clicksRight)).")
        }
    }

    /// Starts from today's counts, so a newly chosen milestone doesn't fire for counts already passed.
    func rebase(_ today: Counts, day: String) {
        tracker.rebase(keys: today.keys, clicks: today.clicks, day: day)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tracker) { UserDefaults.standard.set(data, forKey: Self.key) }
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
