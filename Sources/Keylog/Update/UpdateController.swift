import AppKit
import KeylogCore

/// Keylog keeping itself up to date: the checks, the window, and the install.
///
/// When a check finds a newer release, the window always appears, with every version's notes
/// since the running one. Update Now downloads, installs and reopens Keylog; Later hides the
/// window until the next launch or a day later, whichever comes first.
@MainActor
final class UpdateController {
    let window = UpdateWindowController()
    private let checker = UpdateChecker()
    private let current = UpdateChecker.currentVersion
    var installOptions = UpdateInstaller.Options()
    /// Debug runs watch the phases and the result of an install.
    var onPhase: ((UpdatePhase) -> Void)?
    var onInstalled: ((UpdateInstaller.Outcome) -> Void)?

    private var snoozedUntil: Date?
    private var manualCheck: Task<Void, Never>?
    private var installTask: Task<Void, Never>?

    init(reduceMotion: @escaping () -> Bool) {
        window.reduceMotion = reduceMotion
        window.actions = UpdateActions(
            later: { [weak self] in self?.later() },
            updateNow: { [weak self] in self?.updateNow() },
            cancel: { [weak self] in self?.cancel() },
            tryAgain: { [weak self] in self?.updateNow() },
            downloadManually: { [weak self] in self?.downloadManually() },
            close: { [weak self] in self?.dismiss() })
        window.onEscape = { [weak self] in self?.escape() }
        checker.mayCheck = { [weak self] in self?.window.shownPhase?.isBusy != true && self?.manualCheck == nil }
        checker.onReleases = { [weak self] releases in self?.found(releases) }
    }

    /// Starts or stops the automatic checks. A build without a version (a bare binary) never checks.
    func setAutomatic(_ on: Bool) {
        guard on else {
            checker.stop()
            return
        }
        guard current != nil else {
            NSLog("Keylog: no version in Info.plist, so updates are off")
            return
        }
        checker.start()
    }

    /// "Check for Updates…": checks on any network, and always answers, even when up to date.
    func checkManually() {
        if let shown = window.shownPhase, shown.offer != nil {
            window.show(shown, activate: true)
            return
        }
        guard let current else {
            show(.checkFailed("This copy of Keylog has no version number, so it can't check for updates."), activate: true)
            return
        }
        manualCheck?.cancel()
        manualCheck = Task { @MainActor [weak self] in
            // The checking window shows only when GitHub takes a moment, so it doesn't flash.
            let slow = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                if !Task.isCancelled { self?.show(.checking, activate: true) }
            }
            let phase: UpdatePhase?
            do {
                let releases = try await UpdateChecker.fetch()
                phase = Updates.offer(releases, current: current).map { .ready($0) } ?? .upToDate(current)
            } catch is CancellationError {
                phase = nil
            } catch {
                if Task.isCancelled {
                    phase = nil
                } else {
                    NSLog("Keylog: update check didn't work: %@", UpdateFailure(error).message)
                    phase = .checkFailed(UpdateFailure(error).message + " Try again later.")
                }
            }
            slow.cancel()
            guard let self, !Task.isCancelled else { return }
            self.manualCheck = nil
            if let phase { self.show(phase, activate: true) }
        }
    }

    /// An automatic check's answer.
    private func found(_ releases: [Release]) {
        guard let current, let offer = Updates.offer(releases, current: current) else { return }
        if let shown = window.shownPhase {
            // An even newer version replaces the one waiting; anything else is left alone.
            if case .ready(let waiting) = shown, waiting.release.version < offer.release.version { show(.ready(offer), activate: false) }
            return
        }
        guard UpdatePolicy.mayOffer(snoozedUntil: snoozedUntil, now: Date()) else {
            NSLog("Keylog: Keylog %@ is out; the window waits after Later", offer.release.version.description)
            return
        }
        show(.ready(offer), activate: false)
    }

    private func show(_ phase: UpdatePhase, activate: Bool) {
        window.show(phase, activate: activate)
        onPhase?(phase)
    }

    private func set(_ phase: UpdatePhase) {
        window.set(phase)
        onPhase?(phase)
    }

    // MARK: Buttons

    func later() {
        snoozedUntil = Date().addingTimeInterval(UpdatePolicy.snooze)
        window.close()
    }

    func updateNow() {
        guard installTask == nil, let offer = window.shownPhase?.offer else { return }
        let installer = UpdateInstaller(options: installOptions)
        set(.downloading(offer, received: 0, total: offer.release.dmg.map(\.size)))
        var lastShown = Date.distantPast
        installer.onProgress = { [weak self] received, total in
            guard let self, case .downloading = self.window.state.phase else { return }
            self.window.set(.downloading(offer, received: received, total: total))
            // Debug runs print a few steps, not every update.
            if Date().timeIntervalSince(lastShown) > 0.5 || received == total {
                lastShown = Date()
                self.onPhase?(.downloading(offer, received: received, total: total))
            }
        }
        installer.onInstalling = { [weak self] in self?.set(.installing(offer)) }
        installTask = Task { @MainActor [weak self] in
            do {
                let outcome = try await installer.install(offer)
                self?.installTask = nil
                self?.onInstalled?(outcome)
                switch outcome {
                case .installed(let app, _):
                    // The new version is in place either way; without a relaunch it opens next time.
                    do { try installer.relaunch(app) } catch { NSLog("Keylog: couldn't reopen after the update: %@", "\(error)") }
                    NSApp.terminate(nil)
                case .openedInFinder(let message):
                    self?.set(.manual(offer, message))
                }
            } catch is CancellationError {
                self?.installTask = nil
                self?.set(.ready(offer))
            } catch {
                self?.installTask = nil
                NSLog("Keylog: update didn't install: %@", "\(error)")
                self?.set(.failed(offer, UpdateFailure(error).message))
            }
        }
    }

    /// Stops a download (back to the offer) or a check (the window closes).
    func cancel() {
        if case .downloading = window.shownPhase {
            installTask?.cancel()
            return
        }
        manualCheck?.cancel()
        manualCheck = nil
        window.close()
    }

    /// Opens the release page, where Keylog.dmg can be downloaded by hand.
    func downloadManually() {
        let page = window.state.phase.offer?.release.page
            ?? URL(string: "https://github.com/irfanabdulhameed/keylog/releases/latest")!
        if installOptions.dryOpen {
            print("would open \(page.absoluteString)")
        } else {
            NSWorkspace.shared.open(page)
        }
        later()
    }

    /// OK.
    func dismiss() {
        if case .manual = window.shownPhase { snoozedUntil = Date().addingTimeInterval(UpdatePolicy.snooze) }
        window.close()
    }

    private func escape() {
        switch window.shownPhase {
        case .ready, .failed: later()
        case .downloading, .checking: cancel()
        case .installing, nil: break
        case .upToDate, .checkFailed, .manual: dismiss()
        }
    }
}
