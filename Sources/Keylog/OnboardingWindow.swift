import AppKit
import KeylogCore
import SwiftUI

/// First-launch window: explains what Keylog stores and walks through the
/// Input Monitoring permission, then carries on by itself once it's given.
final class OnboardingWindow: NSObject, NSWindowDelegate {
    var onClose: () -> Void = {}

    private let window: NSWindow
    private let model = OnboardingModel()
    private let tryStart: () -> Bool
    private var pollTimer: Timer?

    /// `tryStart` starts counting and reports whether it worked.
    init(tryStart: @escaping () -> Bool) {
        self.tryStart = tryStart
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(
            model: model,
            openSettings: { [weak self] in self?.openSettings() },
            restart: { Self.relaunch() }))
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startPolling()
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        onClose()
    }

    private func openSettings() {
        EventTap.requestPermission()
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
        model.state = .waiting
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func check() {
        guard EventTap.hasPermission else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        if tryStart() {
            model.state = .granted
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.window.close() }
        } else {
            // Some macOS versions only hand the permission to a fresh launch.
            model.state = .needsRestart
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--relaunched"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

final class OnboardingModel: ObservableObject {
    enum State { case intro, waiting, granted, needsRestart }
    @Published var state = State.intro
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let openSettings: () -> Void
    let restart: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .overlay(alignment: .bottomTrailing) {
                    if model.state == .granted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white, .green)
                            .offset(x: 4, y: 4)
                    }
                }

            Text(title)
                .font(.title2.weight(.semibold))

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            action
                .frame(height: 32)

            Label("Keylog stores counts only, never what you type.", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 440)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.state)
    }

    private var title: String {
        switch model.state {
        case .intro: "Keylog counts your key presses"
        case .waiting: "Switch Keylog on"
        case .granted: "All set"
        case .needsRestart: "One restart needed"
        }
    }

    private var message: String {
        switch model.state {
        case .intro:
            "To count, macOS needs your OK. Open Input Monitoring, switch Keylog on, then come back here."
        case .waiting:
            "In System Settings, go to Privacy & Security → Input Monitoring and turn on Keylog. This window carries on by itself."
        case .granted:
            "Keylog is counting. You'll find it in the menu bar."
        case .needsRestart:
            "macOS has given permission, but Keylog has to restart to use it."
        }
    }

    @ViewBuilder private var action: some View {
        switch model.state {
        case .intro:
            Button("Open Input Monitoring Settings", action: openSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .waiting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for permission…").foregroundStyle(.secondary)
                Button("Open Settings Again", action: openSettings)
                    .buttonStyle(.link)
            }
        case .granted:
            EmptyView()
        case .needsRestart:
            Button("Restart Keylog", action: restart)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}
