import AppKit
import KeylogCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var processor: InputProcessor!
    private let tap = EventTap()
    private let apps = AppTracker()
    private var statusItem: StatusItemController!
    private var widget: WidgetController!
    private var dashboard: DashboardController!
    private var settings: SettingsController!
    private var onboarding: OnboardingWindow?
    private var flushTimer: Timer?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard isOnlyCopy() else {
            NSApp.terminate(nil)
            return
        }
        let store: Store
        do {
            store = try Store()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Keylog can't open its data file"
            alert.informativeText = "\(Store.defaultPath)\n\n\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let recorder = Recorder(store: store)
        recorder.tracksApps = Preferences.tracksApps
        recorder.currentApp = { [apps] in apps.current }
        model = AppModel(store: store, recorder: recorder)
        recorder.onChange = { [weak model] in model?.recorderChanged() }

        processor = InputProcessor(recorder: recorder, displays: DisplayScale.current())
        processor.tracksMouse = model.tracksMouse
        processor.isPaused = model.isPaused
        model.onPauseChange = { [weak processor] paused in processor?.isPaused = paused }
        model.onTrackMouseChange = { [weak processor] on in processor?.tracksMouse = on }

        widget = WidgetController(model: model)
        tap.onEvent = { [processor, widget] event, date, uptime in
            processor?.handle(event, at: date, uptime: uptime)
            switch event {
            case let .move(point): widget?.pointerMoved(to: point)
            case let .modifier(code, isDown, _) where code == 59 || code == 62: widget?.controlChanged(held: isDown)
            default: break
            }
        }

        tap.onResume = { [processor] in processor?.resetState() }

        settings = SettingsController(model: model) { [unowned self] in self.actions }
        dashboard = DashboardController(model: model) { [weak self] in self?.settings.show() }
        statusItem = StatusItemController(model: model, actions: actions)
        widget.actions = actions

        startCounting()
        observeSystem()
        handleTerminationSignal()

        // Save every 30 seconds, and roll over to a new hour or day even when idle.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let model = self?.model else { return }
            model.recorder.tick()
            model.recorder.flush()
            model.publish()
            if model.firstDay == nil { model.refreshFirstDay() }
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.recorder.flush(wait: true)
    }

    /// Reopening Keylog from Finder or Spotlight opens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dashboard.show(.overview)
        return false
    }

    /// Two running copies would both count every key. If one is already running,
    /// bring it forward and quit. After a permission restart the old copy is still
    /// on its way out, so wait for it instead.
    private func isOnlyCopy() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return true }
        func others() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != .current && !$0.isTerminated }
        }
        if CommandLine.arguments.contains("--relaunched") {
            let deadline = Date().addingTimeInterval(5)
            while !others().isEmpty && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            return true
        }
        if let running = others().first {
            running.activate()
            return false
        }
        return true
    }

    private var actions: AppActions {
        AppActions(
            openDashboard: { [weak self] section in self?.dashboard.show(section) },
            openSettings: { [weak self] in self?.settings.show() },
            allowAccess: { [weak self] in self?.showOnboarding() },
            moveWidget: { [weak self] in
                self?.model.widget.isVisible = true
                self?.model.isMovingWidget = true
            })
    }

    /// Starts the event tap, or asks for permission when macOS hasn't given it yet.
    private func startCounting() {
        let started = EventTap.hasPermission && tap.start()
        model.setCounting(started)
        if !started { showOnboarding() }
    }

    private func showOnboarding() {
        if let onboarding {
            onboarding.show()
            return
        }
        let window = OnboardingWindow { [weak self] in
            guard let self, EventTap.hasPermission, self.tap.start() else { return false }
            self.model.setCounting(true)
            return true
        }
        window.onClose = { [weak self] in self?.onboarding = nil }
        onboarding = window
        window.show()
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.model.recorder.flush(wait: true)
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.processor.resetState()
            self?.model.recorder.tick()
            self?.model.publish()
        }

        let center = NotificationCenter.default
        center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            NSTimeZone.resetSystemTimeZone()
            self?.model.recorder.setClock(DayClock(timeZone: .current))
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSCalendarDayChanged] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.model.recorder.tick()
                self?.model.publish()
            }
        }
        center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.processor.updateDisplays(DisplayScale.current())
        }
    }

    /// `kill` and `pkill` send SIGTERM; quit properly so the last counts are saved.
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }
}

/// Follows which app is in front, for per-app counts. Only the name is kept.
final class AppTracker {
    private(set) var current: (id: String, name: String) = ("", "")
    private var observer: NSObjectProtocol?

    init() {
        set(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            self?.set(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    private func set(_ app: NSRunningApplication?) {
        guard let app else { return }
        let id = app.bundleIdentifier ?? app.executableURL?.lastPathComponent ?? ""
        current = (id, app.localizedName ?? id)
    }
}
