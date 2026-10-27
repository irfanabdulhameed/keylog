import AppKit
import SwiftUI
import KeylogCore

/// The update window: a floating panel in the middle of the screen, on frosted material,
/// sized to what it shows. It opens and closes the way macOS opens and closes an alert (a
/// short fade and scale); with Reduce motion it only fades, in 0.2 s.
///
/// An automatic check shows it without taking the keyboard from the app in front, so a
/// Return meant for another app can't press Update Now. A click on it, or a check the user
/// asked for, makes it key: then Return is Update Now and Esc is Later.
@MainActor
final class UpdateWindowController {
    let state = UpdateState()
    var actions = UpdateActions.none
    /// Esc, in any phase. Mapped by the app to Later, Cancel or OK.
    var onEscape: () -> Void = {}
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// For the debug commands: the window is made and laid out like a real one but stays
    /// invisible, off every screen, and never takes focus.
    var headless = false

    /// The reduced-motion fade in, and out.
    static let fadeIn: TimeInterval = 0.2
    static let fadeOut: TimeInterval = 0.15

    private(set) var panel: UpdatePanel?
    private var closing = false

    /// What the window shows, when it is on screen.
    var shownPhase: UpdatePhase? {
        guard let panel, panel.isVisible, !closing else { return nil }
        return state.phase
    }

    /// Shows `phase`, opening the window if it isn't open. `activate` brings Keylog forward
    /// and gives the window the keyboard; for a check the user asked for.
    func show(_ phase: UpdatePhase, activate: Bool) {
        let panel = ensurePanel()
        let wasShown = shownPhase != nil
        set(phase)
        if wasShown {
            if activate { bringForward(panel) }
            return
        }
        closing = false
        fit(animated: false)
        panel.center()
        present(panel, activate: activate)
    }

    /// Changes what the open window shows. The window grows or shrinks around its top edge.
    func set(_ phase: UpdatePhase) {
        let old = state.phase
        if let offer = phase.offer, offer.releases.map(\.tag) != old.offer?.releases.map(\.tag) {
            state.notesHeight = UpdateLayout.notesHeight(offer.releases)
        }
        state.phase = phase
        if old.sizeKey != phase.sizeKey, let panel, panel.isVisible { fit(animated: true) }
    }

    func close() {
        guard let panel, panel.isVisible, !closing else { return }
        if headless || !reduceMotion() {
            panel.animationBehavior = headless ? .none : .alertPanel
            panel.orderOut(nil)
            if !headless { DockPresence.hide(.update) }
            return
        }
        closing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closing else { return }
                self.closing = false
                panel.orderOut(nil)
                panel.alphaValue = 1
                DockPresence.hide(.update)
            }
        }
    }

    // MARK: Window

    private func ensurePanel() -> UpdatePanel {
        if let panel { return panel }
        let panel = UpdatePanel(contentRect: NSRect(x: 0, y: 0, width: UpdateLayout.width, height: 300),
                                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.title = "Keylog Update"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        // Keylog is a menu bar app and is rarely the active one: the window stays anyway.
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.onEscape = { [weak self] in self?.onEscape() }

        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        // Frosted even while another app is active, which is most of the time.
        material.state = .active
        let hosting = FirstClickHostingView(rootView: UpdateRoot(state: state, actions: Self.forward(self)))
        hosting.sizingOptions = []
        hosting.frame = material.bounds
        hosting.autoresizingMask = [.width, .height]
        material.addSubview(hosting)
        panel.contentView = material
        self.panel = panel
        return panel
    }

    /// The buttons call through the controller, so `actions` can be set after the window is made.
    private static func forward(_ controller: UpdateWindowController) -> UpdateActions {
        UpdateActions(
            later: { [weak controller] in controller?.actions.later() },
            updateNow: { [weak controller] in controller?.actions.updateNow() },
            cancel: { [weak controller] in controller?.actions.cancel() },
            tryAgain: { [weak controller] in controller?.actions.tryAgain() },
            downloadManually: { [weak controller] in controller?.actions.downloadManually() },
            close: { [weak controller] in controller?.actions.close() })
    }

    /// Sizes the window to its content, keeping its top edge and its centre where they are.
    private func fit(animated: Bool) {
        guard let panel else { return }
        let size = UpdateLayout.size(state.phase, notesHeight: state.notesHeight, icon: state.icon)
        let old = panel.frame
        var frame = NSRect(origin: old.origin, size: size)
        if panel.isVisible {
            frame.origin.x = (old.midX - size.width / 2).rounded()
            frame.origin.y = old.maxY - size.height
        }
        guard frame != old else { return }
        panel.setFrame(frame, display: true, animate: animated && panel.isVisible && !headless && !reduceMotion())
    }

    private func present(_ panel: UpdatePanel, activate: Bool) {
        if headless {
            panel.animationBehavior = .none
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            panel.orderFrontRegardless()
            return
        }
        // While it shows, Keylog is in the Dock and ⌘-Tab, so it can be found again.
        DockPresence.show(.update)
        let reduce = reduceMotion()
        // macOS's own alert motion, which fades and scales; or only a fade.
        panel.animationBehavior = reduce ? .none : .alertPanel
        panel.alphaValue = reduce ? 0 : 1
        if activate {
            bringForward(panel)
        } else {
            panel.orderFrontRegardless()
        }
        if reduce {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeIn
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func bringForward(_ panel: UpdatePanel) {
        guard !headless else { return }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }
}

/// Takes the first click even while Keylog isn't the active app, so a button works at once.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The update window. It can take the keyboard without making Keylog the active app.
final class UpdatePanel: NSPanel {
    var onEscape: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc, when no button took it.
    override func cancelOperation(_ sender: Any?) { onEscape() }
}
