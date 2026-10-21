import CoreGraphics
import Foundation
import Testing
@testable import KeylogCore

private let kolkata = TimeZone(identifier: "Asia/Kolkata")!

private func date(_ text: String, in zone: TimeZone = kolkata) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.date(from: text)!
}

private func temporaryStorePath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("keylog-test-\(UUID().uuidString).sqlite").path
}

/// A recorder and processor on a throwaway database with a hand-driven clock.
private final class Rig {
    let store: Store
    let recorder: Recorder
    let processor: InputProcessor
    var now: Date
    var uptime = 1000.0
    var app = (id: "com.apple.TextEdit", name: "TextEdit")

    private let path: String

    init(start: String = "2026-10-21 10:00:00", path: String = temporaryStorePath()) throws {
        self.path = path
        store = try Store(path: path)
        now = date(start)
        recorder = Recorder(store: store, clock: DayClock(timeZone: kolkata), now: now)
        processor = InputProcessor(
            recorder: recorder,
            displays: [DisplayScale(bounds: CGRect(x: 0, y: 0, width: 1000, height: 1000), mmPerPoint: 0.25)])
        recorder.currentApp = { [unowned self] in self.app }
    }

    deinit {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    func send(_ event: InputEvent, after seconds: Double = 0.2) {
        now += seconds
        uptime += seconds
        processor.handle(event, at: now, uptime: uptime)
    }

    func key(_ code: UInt16, _ character: Character?, repeat isRepeat: Bool = false, after seconds: Double = 0.2) {
        send(.key(code: code, character: character, isRepeat: isRepeat), after: seconds)
    }

    func saved(_ day: String) -> Counts {
        recorder.flush(wait: true)
        return store.totals(day: day)
    }
}

@Suite struct ClassifierTests {
    @Test func groups() {
        #expect(KeyClassifier.group(keyCode: 0, character: "a") == .letters)
        #expect(KeyClassifier.group(keyCode: 0, character: "A") == .letters)
        #expect(KeyClassifier.group(keyCode: 14, character: "é") == .letters)
        #expect(KeyClassifier.group(keyCode: 18, character: "1") == .numbers)
        #expect(KeyClassifier.group(keyCode: 83, character: "1") == .numbers)  // keypad 1
        #expect(KeyClassifier.group(keyCode: 18, character: "!") == .special)
        #expect(KeyClassifier.group(keyCode: 47, character: ".") == .special)
        #expect(KeyClassifier.group(keyCode: 49, character: " ") == .space)
        #expect(KeyClassifier.group(keyCode: 36, character: "\r") == .other)  // Return
        #expect(KeyClassifier.group(keyCode: 51, character: "\u{8}") == .other)  // Delete
        #expect(KeyClassifier.group(keyCode: 123, character: nil) == .other)  // left arrow
        #expect(KeyClassifier.group(keyCode: 122, character: "\u{F704}") == .other)  // F1
        #expect(KeyClassifier.group(keyCode: 0, character: nil) == .other)
    }

    @Test func modifierFlags() {
        #expect(ModifierKey.isDown(code: 55, flags: 0x10_0108))  // left ⌘ held
        #expect(!ModifierKey.isDown(code: 54, flags: 0x10_0108))  // right ⌘ not held
        #expect(!ModifierKey.isModifier(0))
    }
}

@Suite struct CountingRuleTests {
    @Test func heldKeyCountsOnce() throws {
        let rig = try Rig()
        rig.key(0, "a")
        rig.key(0, nil, repeat: true)
        rig.key(0, nil, repeat: true)
        #expect(rig.recorder.today.letters == 1)
        #expect(rig.recorder.today.keys == 1)
    }

    @Test func modifierTappedAloneCountsAsOther() throws {
        let rig = try Rig()
        rig.send(.modifier(code: 56, isDown: true))
        rig.send(.modifier(code: 56, isDown: false))
        #expect(rig.recorder.today.other == 1)
        #expect(rig.recorder.today.keys == 1)
        rig.recorder.flush(wait: true)
        #expect(rig.store.keyCounts(from: "2026-10-21", through: "2026-10-21")[56] == 1)
    }

    @Test func shortcutCountsOnlyTheKeyButLightsTheModifier() throws {
        let rig = try Rig()
        rig.send(.modifier(code: 55, isDown: true))
        rig.key(8, "c")
        rig.send(.modifier(code: 55, isDown: false))
        // A capital letter: Shift is part of it, so only the letter counts.
        rig.send(.modifier(code: 56, isDown: true))
        rig.key(0, "A")
        rig.send(.modifier(code: 56, isDown: false))
        #expect(rig.recorder.today.letters == 2)
        #expect(rig.recorder.today.keys == 2)
        rig.recorder.flush(wait: true)
        let heat = rig.store.keyCounts(from: "2026-10-21", through: "2026-10-21")
        #expect(heat == [55: 1, 8: 1, 56: 1, 0: 1])
    }

    @Test func twoModifiersTogetherAreNotATap() throws {
        let rig = try Rig()
        rig.send(.modifier(code: 55, isDown: true))
        rig.send(.modifier(code: 56, isDown: true))
        rig.send(.modifier(code: 56, isDown: false))
        rig.send(.modifier(code: 55, isDown: false))
        #expect(rig.recorder.today.keys == 0)
    }

    @Test func commandClickIsNotATap() throws {
        let rig = try Rig()
        rig.send(.modifier(code: 55, isDown: true))
        rig.send(.click(.left))
        rig.send(.modifier(code: 55, isDown: false))
        #expect(rig.recorder.today.keys == 0)
        #expect(rig.recorder.today.clicksLeft == 1)
    }

    @Test func modifierScrollIsNotATap() throws {
        let rig = try Rig()
        rig.send(.modifier(code: 56, isDown: true))
        rig.send(.scroll(dx: 40, dy: 0, isMomentum: false))  // ⇧-scroll: sideways
        rig.send(.modifier(code: 56, isDown: false))
        #expect(rig.recorder.today.keys == 0)
    }

    @Test func missedReleaseDoesNotStick() throws {
        let rig = try Rig()
        rig.send(.modifier(code: 55, isDown: true, flags: 0x10_0108))  // ⌘ down; its release is never seen
        rig.send(.modifier(code: 56, isDown: true, flags: 0x2_0102))  // ⇧ down, flags say ⌘ is up
        rig.send(.modifier(code: 56, isDown: false, flags: 0x100))
        #expect(rig.recorder.today.other == 1)  // the ⇧ tap still counts
    }

    @Test func capsLockCountsEachPress() throws {
        let rig = try Rig()
        rig.send(.capsLock)
        rig.send(.capsLock)
        #expect(rig.recorder.today.other == 2)
    }

    @Test func clicksByButton() throws {
        let rig = try Rig()
        rig.send(.click(.left))
        rig.send(.click(.left))
        rig.send(.click(.right))
        rig.send(.click(.middle))
        rig.send(.click(.other))
        let saved = rig.saved("2026-10-21")
        #expect(saved.clicksLeft == 2 && saved.clicksRight == 1)
        #expect(saved.clicksMiddle == 0 && saved.clicksOther == 0)  // side and wheel buttons don't count
        #expect(saved.clicks == 3)
    }

    @Test func mouseTravelIgnoresWarps() throws {
        let rig = try Rig()
        rig.send(.move(CGPoint(x: 0, y: 0)))
        rig.send(.move(CGPoint(x: 300, y: 400)))  // 500 pt × 0.25 mm = 125 mm
        rig.send(.move(CGPoint(x: 990, y: 990)))  // a 900 pt jump: a warp, ignored
        rig.send(.move(CGPoint(x: 990, y: 950)))  // 40 pt = 10 mm
        #expect(abs(rig.recorder.today.mouseMM - 135) < 0.001)
    }

    @Test func scrollIgnoresMomentum() throws {
        let rig = try Rig()
        rig.send(.move(CGPoint(x: 10, y: 10)))
        rig.send(.scroll(dx: 0, dy: 40, isMomentum: false))
        rig.send(.scroll(dx: 0, dy: 400, isMomentum: true))
        #expect(abs(rig.recorder.today.scrollMM - 10) < 0.001)
    }

    @Test func pausedCountsNothing() throws {
        let rig = try Rig()
        rig.processor.isPaused = true
        rig.key(0, "a")
        rig.send(.click(.left))
        rig.processor.isPaused = false
        rig.key(0, "a")
        #expect(rig.recorder.today.keys == 1)
        #expect(rig.recorder.today.clicks == 0)
    }

    @Test func mouseOffStillCountsKeys() throws {
        let rig = try Rig()
        rig.processor.tracksMouse = false
        rig.send(.move(CGPoint(x: 0, y: 0)))
        rig.send(.move(CGPoint(x: 100, y: 0)))
        rig.key(0, "a")
        #expect(rig.recorder.today.mouseMM == 0)
        #expect(rig.recorder.today.keys == 1)
    }
}

@Suite struct SpeedTests {
    @Test func peakIsBusiestSecond() throws {
        let rig = try Rig()
        for _ in 0..<6 { rig.key(0, "a", after: 0.1) }  // 6 keys within 0.6 s
        for _ in 0..<3 { rig.key(0, "a", after: 1.5) }  // slow keys
        #expect(rig.recorder.today.peakKPS == 6)
        #expect(rig.saved("2026-10-21").peakKPS == 6)
    }

    @Test func activeMinutes() throws {
        let rig = try Rig(start: "2026-10-21 10:00:00")
        rig.key(0, "a", after: 5)  // 10:00
        rig.key(0, "a", after: 5)  // 10:00
        rig.key(0, "a", after: 60)  // 10:01
        rig.key(0, "a", after: 120)  // 10:03
        #expect(rig.recorder.today.activeMinutes == 3)
        #expect(rig.saved("2026-10-21").activeMinutes == 3)
        #expect(rig.recorder.today.keysPerActiveMinute == 4.0 / 3.0)
    }
}

@Suite struct TimeTests {
    @Test func midnightStartsANewDay() throws {
        let rig = try Rig(start: "2026-10-21 23:59:00")
        rig.key(0, "a", after: 30)  // 23:59:30
        rig.key(0, "a", after: 1)
        #expect(rig.recorder.today.keys == 2)
        rig.key(0, "a", after: 40)  // 00:00:11 next day
        #expect(rig.recorder.currentDay == "2026-10-22")
        #expect(rig.recorder.today.keys == 1)
        #expect(rig.saved("2026-10-21").keys == 2)
        #expect(rig.saved("2026-10-22").keys == 1)
    }

    @Test func idleTickAtMidnightResetsToday() throws {
        let rig = try Rig(start: "2026-10-21 23:00:00")
        rig.key(0, "a")
        rig.recorder.tick(date("2026-10-22 00:00:01"))
        #expect(rig.recorder.today.keys == 0)
        #expect(rig.saved("2026-10-21").keys == 1)
    }

    @Test func sleepingOverMidnight() throws {
        let rig = try Rig(start: "2026-10-21 22:00:00")
        rig.key(0, "a")
        rig.recorder.flush(wait: true)  // the Mac sleeps
        rig.key(0, "a", after: 10 * 3600)  // first key after waking, next morning
        #expect(rig.recorder.currentDay == "2026-10-22")
        #expect(rig.recorder.today.keys == 1)
        #expect(rig.saved("2026-10-21").keys == 1)
    }

    @Test func timeZoneChangeKeepsPastHours() throws {
        let rig = try Rig(start: "2026-10-21 10:00:00")
        rig.key(0, "a")
        let london = TimeZone(identifier: "Europe/London")!
        rig.recorder.setClock(DayClock(timeZone: london), now: rig.now)
        rig.key(0, "a")
        rig.recorder.flush(wait: true)
        let rows = rig.store.hours(from: "2026-10-21", through: "2026-10-21")
        #expect(rows.map(\.timeZone) == ["Europe/London", "Asia/Kolkata"])  // 05:00 London, 10:00 Kolkata
        #expect(rows.map(\.hour) == [5, 10])
    }

    @Test func restartContinuesToday() throws {
        let path = temporaryStorePath()
        let first = try Rig(start: "2026-10-21 10:00:00", path: path)
        first.key(0, "a", after: 1)
        first.key(18, "1", after: 1)
        first.recorder.flush(wait: true)
        let rig = try Rig(start: "2026-10-21 10:00:05", path: path)
        #expect(rig.recorder.today.letters == 1)
        #expect(rig.recorder.today.numbers == 1)
        #expect(rig.recorder.today.activeMinutes == 1)
        rig.key(0, "a")  // same minute: not a new active minute
        #expect(rig.recorder.today.activeMinutes == 1)
        #expect(rig.store.firstDay() == "2026-10-21")
    }
}

@Suite struct AppTests {
    @Test func countsGoToTheFrontApp() throws {
        let rig = try Rig()
        rig.key(0, "a")
        rig.send(.click(.left))
        rig.app = (id: "com.apple.Safari", name: "Safari")
        rig.key(0, "a")
        rig.key(0, "a")
        rig.recorder.flush(wait: true)
        let apps = rig.store.apps(from: "2026-10-21", through: "2026-10-21")
        #expect(apps["com.apple.TextEdit"]?.keys == 1)
        #expect(apps["com.apple.TextEdit"]?.clicks == 1)
        #expect(apps["com.apple.Safari"]?.keys == 2)
        #expect(rig.store.keyCounts(from: "2026-10-21", through: "2026-10-21", app: "com.apple.Safari") == [0: 2])
    }

    @Test func appTrackingOffStoresNoApps() throws {
        let rig = try Rig()
        rig.recorder.tracksApps = false
        rig.key(0, "a")
        rig.recorder.flush(wait: true)
        #expect(rig.store.apps(from: "2026-10-21", through: "2026-10-21").isEmpty)
        #expect(rig.store.keyCounts(from: "2026-10-21", through: "2026-10-21") == [0: 1])
    }
}
