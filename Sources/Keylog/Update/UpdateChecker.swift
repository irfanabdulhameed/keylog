import AppKit
import Network
import KeylogCore

/// Decides when to ask GitHub for new versions, and asks. Runs only while "Check for updates
/// automatically" is on in Settings, which it isn't until the user switches it on.
///
/// Only on Wi-Fi or Ethernet: never on a phone's hotspot or with Low Data Mode on. About 10 s
/// after launch, then every 6 hours, when such a network comes back, and when the Mac wakes;
/// the last two not within 15 minutes of the previous check. A check that fails is only logged.
/// The request is the list of releases and nothing else.
@MainActor
final class UpdateChecker {
    /// Asked before each check: false while the update window is busy.
    var mayCheck: () -> Bool = { true }
    var onReleases: ([Release]) -> Void = { _ in }

    private var monitor: NWPathMonitor?
    private var networkAllows = false
    private var sawFirstPath = false
    private var lastCheck: Date?
    private var pending: Timer?
    private var pendingFire: Date?
    private var pendingReason = UpdatePolicy.Reason.launch
    private var regular: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var running = false

    func start() {
        guard wakeObserver == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let allows = UpdatePolicy.networkAllows(satisfied: path.status == .satisfied,
                                                    expensive: path.isExpensive, constrained: path.isConstrained)
            MainActor.assumeIsolated { self?.networkChanged(allows) }
        }
        monitor.start(queue: .main)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The network takes a moment to come back after a wake.
            MainActor.assumeIsolated { self?.schedule(.wake, after: 5) }
        }
        schedule(.launch, after: UpdatePolicy.launchDelay)
        scheduleRegular()
    }

    /// Stops every automatic check. A check already on its way still answers.
    func stop() {
        monitor?.cancel()
        monitor = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        pending?.invalidate()
        pending = nil
        pendingFire = nil
        regular?.invalidate()
        regular = nil
        sawFirstPath = false
        networkAllows = false
    }

    var isRunning: Bool { wakeObserver != nil }

    private func networkChanged(_ allows: Bool) {
        let was = networkAllows
        networkAllows = allows
        // The first answer only says how things are at launch; the launch check covers it.
        guard sawFirstPath else {
            sawFirstPath = true
            return
        }
        if allows && !was { schedule(.network, after: 3) }
    }

    /// One check at a time: a sooner one replaces a later one.
    private func schedule(_ reason: UpdatePolicy.Reason, after delay: TimeInterval) {
        let fire = Date().addingTimeInterval(delay)
        if let pendingFire, pendingFire <= fire { return }
        pending?.invalidate()
        pendingFire = fire
        pendingReason = reason
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pending = timer
    }

    private func scheduleRegular() {
        regular?.invalidate()
        let timer = Timer(timeInterval: UpdatePolicy.interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(.timer, after: 0) }
        }
        RunLoop.main.add(timer, forMode: .common)
        regular = timer
    }

    private func fire() {
        let reason = pendingReason
        pending = nil
        pendingFire = nil
        let now = Date()
        guard !running, UpdatePolicy.shouldCheck(reason, lastCheck: lastCheck, now: now) else { return }
        // The 6-hour clock starts again from every attempt.
        scheduleRegular()
        guard networkAllows else {
            NSLog("Keylog: update check (%@) waits for Wi-Fi or Ethernet", reason.rawValue)
            return
        }
        guard mayCheck() else { return }
        lastCheck = now
        running = true
        Task { @MainActor in
            defer { running = false }
            do {
                onReleases(try await Self.fetch())
            } catch {
                NSLog("Keylog: update check (%@) didn't work: %@", reason.rawValue, UpdateFailure(error).message)
            }
        }
    }

    // MARK: The request

    /// GitHub's list of releases. `defaults write <bundle id> updateFeedURL <url>`, or the
    /// launch argument `-updateFeedURL <url>`, points it at a local file or server instead.
    nonisolated static var feedURL: URL {
        if let text = UserDefaults.standard.string(forKey: "updateFeedURL"), let url = URL(string: text), url.scheme != nil {
            return url
        }
        return ReleaseFeed.defaultURL
    }

    /// The running version, from Info.plist. nil for a bare build, which never updates.
    nonisolated static var currentVersion: SemanticVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(SemanticVersion.init)
    }

    /// Asks for the list. No token, no cookies, no cache, nothing about the user or their files.
    nonisolated static func fetch(from url: URL = feedURL) async throws -> [Release] {
        if url.isFileURL { return try ReleaseFeed.parse(try Data(contentsOf: url)) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Keylog/\(currentVersion?.description ?? "0")", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateFailure.unreadable }
        guard http.statusCode == 200 else { throw UpdateFailure.status(http.statusCode) }
        return try ReleaseFeed.parse(data)
    }
}
