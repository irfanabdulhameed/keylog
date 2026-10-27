import AppKit
import SwiftUI
import KeylogCore

/// What the update window shows.
enum UpdatePhase: Equatable {
    /// A check the user asked for, still running.
    case checking
    /// A check the user asked for found nothing newer than this version.
    case upToDate(SemanticVersion)
    /// A check the user asked for didn't work. Automatic checks fail silently.
    case checkFailed(String)
    /// A newer version, waiting for Update Now or Later.
    case ready(UpdateOffer)
    case downloading(UpdateOffer, received: Int64, total: Int64?)
    case installing(UpdateOffer)
    case failed(UpdateOffer, String)
    /// Keylog couldn't replace itself where it is, so the new disk image is open in Finder.
    case manual(UpdateOffer, String)

    var offer: UpdateOffer? {
        switch self {
        case .ready(let offer), .downloading(let offer, _, _), .installing(let offer),
             .failed(let offer, _), .manual(let offer, _): offer
        case .checking, .upToDate, .checkFailed: nil
        }
    }

    /// The small window: checking, up to date, or the check failed.
    var isCompact: Bool { offer == nil }

    /// Downloading or installing: the window can't be dismissed and no other check starts.
    var isBusy: Bool {
        switch self {
        case .downloading, .installing: true
        default: false
        }
    }

    /// Changes whenever the window's height might: not on every byte downloaded.
    var sizeKey: String {
        let tags = offer?.releases.map(\.tag).joined(separator: ",") ?? ""
        switch self {
        case .checking: return "checking"
        case .upToDate(let version): return "upToDate \(version)"
        case .checkFailed(let message): return "checkFailed \(message)"
        case .ready: return "ready \(tags)"
        case .downloading: return "downloading \(tags)"
        case .installing: return "installing \(tags)"
        case .failed(_, let message): return "failed \(tags) \(message)"
        case .manual(_, let message): return "manual \(tags) \(message)"
        }
    }

    /// Which footer the full window shows, for its cross-fade.
    var footerKind: Int {
        switch self {
        case .checking, .upToDate, .checkFailed: 0
        case .ready: 1
        case .downloading: 2
        case .installing: 3
        case .failed: 4
        case .manual: 5
        }
    }
}

/// What the update window's buttons do.
struct UpdateActions {
    var later: () -> Void
    var updateNow: () -> Void
    /// Stops a download or a check.
    var cancel: () -> Void
    var tryAgain: () -> Void
    /// Opens the release page in the browser.
    var downloadManually: () -> Void
    /// OK: closes the window.
    var close: () -> Void

    /// Does nothing. For renders.
    static let none = UpdateActions(later: {}, updateNow: {}, cancel: {}, tryAgain: {}, downloadManually: {}, close: {})
}

/// The update window's sizes, in points.
enum UpdateLayout {
    static let width: CGFloat = 480
    static let compactWidth: CGFloat = 300
    static let padding: CGFloat = 20
    static let iconSize: CGFloat = 64
    /// Taller notes scroll.
    static let notesMaxHeight: CGFloat = 240
    static var notesWidth: CGFloat { width - 2 * padding }
    /// Content cross-fades between states this fast; the window itself moves the way macOS moves it.
    static let fade = 0.18

    /// How tall the notes are, up to `notesMaxHeight`. Measured on their own, so the window
    /// can be sized before it shows.
    @MainActor static func notesHeight(_ releases: [Release]) -> CGFloat {
        let probe = NSHostingView(rootView: NotesList(releases: releases).frame(width: notesWidth))
        return min(probe.fittingSize.height.rounded(.up) + 1, notesMaxHeight)
    }

    /// The window's size for a phase: its content's own size.
    @MainActor static func size(_ phase: UpdatePhase, notesHeight: CGFloat, icon: NSImage) -> NSSize {
        let probe = NSHostingView(rootView: UpdateContent(phase: phase, notesHeight: notesHeight, icon: icon, actions: .none))
        let size = probe.fittingSize
        return NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }
}

/// What the window shows, kept outside the view so the app can change it.
@MainActor
final class UpdateState: ObservableObject {
    @Published var phase: UpdatePhase = .checking
    @Published var notesHeight: CGFloat = UpdateLayout.notesMaxHeight
    var icon: NSImage = NSApp.applicationIconImage
}

/// The window's whole content, wired to the state.
struct UpdateRoot: View {
    @ObservedObject var state: UpdateState
    let actions: UpdateActions
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        UpdateContent(phase: state.phase, notesHeight: state.notesHeight, icon: state.icon, actions: actions)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                // A picture can't draw the frosted material behind the window: a flat stand-in.
                if UpdateRender.isRendering { Rectangle().fill(scheme == .dark ? Color(white: 0.17) : Color(white: 0.95)) }
            }
            // The title bar is see-through and has no buttons: the content fills the window.
            .ignoresSafeArea()
    }
}

/// The content for one phase, at its own size. The window is sized to it.
struct UpdateContent: View {
    let phase: UpdatePhase
    let notesHeight: CGFloat
    let icon: NSImage
    let actions: UpdateActions

    var body: some View {
        ZStack(alignment: .top) {
            if let offer = phase.offer {
                UpdatePane(offer: offer, phase: phase, notesHeight: notesHeight, icon: icon, actions: actions)
                    .transition(.opacity)
            } else {
                CompactPane(phase: phase, icon: icon, actions: actions)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: UpdateLayout.fade), value: phase.isCompact)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: The update

/// A new version: the icon and title, what's new, and the buttons or the progress.
private struct UpdatePane: View {
    let offer: UpdateOffer
    let phase: UpdatePhase
    let notesHeight: CGFloat
    let icon: NSImage
    let actions: UpdateActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                AppIcon(image: icon)
                VStack(alignment: .leading, spacing: 4) {
                    Text("A new version of Keylog is ready")
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(UpdateText.available(offer))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            Text("What's new")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 18)
                .padding(.bottom, 8)

            NotesBox(releases: offer.releases, height: notesHeight)

            ZStack(alignment: .leading) {
                footer
                    .id(phase.footerKind)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .animation(.easeOut(duration: UpdateLayout.fade), value: phase.footerKind)
            .padding(.top, 16)
        }
        .padding(UpdateLayout.padding)
        .frame(width: UpdateLayout.width)
    }

    @ViewBuilder private var footer: some View {
        switch phase {
        case .ready:
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                FooterButton("Later", action: actions.later)
                    .keyboardShortcut(.cancelAction)
                FooterButton("Update Now", action: actions.updateNow)
                    .keyboardShortcut(.defaultAction)
            }

        case .downloading(_, let received, let total):
            HStack(alignment: .center, spacing: 16) {
                Progress(fraction: total.map { $0 > 0 ? min(Double(received) / Double($0), 1) : 0 },
                         text: "Downloading… " + UpdateText.progress(received: received, total: total))
                FooterButton("Cancel", action: actions.cancel)
                    .keyboardShortcut(.cancelAction)
            }

        case .installing:
            Progress(fraction: nil, text: "Installing…")

        case .failed(_, let message):
            VStack(alignment: .leading, spacing: 14) {
                Notice(symbol: "exclamationmark.triangle.fill", text: message)
                HStack(spacing: 10) {
                    FooterButton("Download Manually", action: actions.downloadManually)
                    Spacer(minLength: 0)
                    FooterButton("Later", action: actions.later)
                        .keyboardShortcut(.cancelAction)
                    FooterButton("Try Again", action: actions.tryAgain)
                        .keyboardShortcut(.defaultAction)
                }
            }

        case .manual(_, let message):
            VStack(alignment: .leading, spacing: 14) {
                Notice(symbol: "info.circle.fill", text: message, tint: .accentColor)
                HStack {
                    Spacer(minLength: 0)
                    FooterButton("OK", action: actions.close)
                        .keyboardShortcut(.defaultAction)
                }
            }

        case .checking, .upToDate, .checkFailed:
            EmptyView()
        }
    }
}

/// A determinate bar with its line of text, or a moving one when `fraction` is nil.
private struct Progress: View {
    let fraction: Double?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .accessibilityLabel(fraction == nil ? "Installing" : "Download")
            .accessibilityValue(text)
            Text(text)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A line with a symbol in front: what went wrong (the yellow caution triangle), or what to
/// do next (`tint`).
private struct Notice: View {
    let symbol: String
    let text: String
    var tint: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let tint {
                    Image(systemName: symbol).foregroundStyle(tint)
                } else {
                    Image(systemName: symbol).symbolRenderingMode(.multicolor)
                }
            }
            .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .combine)
    }
}

/// A push button with the width macOS gives dialog buttons at the least.
private struct FooterButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).frame(minWidth: 62)
        }
    }
}

private struct AppIcon: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: UpdateLayout.iconSize, height: UpdateLayout.iconSize)
            .accessibilityHidden(true)
    }
}

// MARK: What's new

/// The notes in their rounded well; they scroll when taller than the well.
private struct NotesBox: View {
    let releases: [Release]
    let height: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ScrollView(.vertical) {
            NotesList(releases: releases)
        }
        .scrollIndicators(.automatic)
        .frame(height: height)
        .background(shape.fill(Color.primary.opacity(0.045)))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
    }
}

/// Every version's heading and date, then its notes as a list, newest first.
struct NotesList: View {
    let releases: [Release]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(releases, id: \.tag) { release in
                ReleaseBlock(release: release)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReleaseBlock: View {
    let release: Release

    var body: some View {
        let lines = ReleaseNotes.lines(release.notes)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Keylog \(release.version.description)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if let date = release.published {
                    Text(date, format: .dateTime.day().month(.wide).year())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .padding(.bottom, 1)

            if lines.isEmpty {
                Text("No notes for this version.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                NoteRow(line: line)
            }
        }
    }
}

private struct NoteRow: View {
    let line: NoteLine

    var body: some View {
        switch line.kind {
        case .heading:
            Text(Self.markdown(line.text))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 3)
                .fixedSize(horizontal: false, vertical: true)
        case .item(let level):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(level == 0 ? "•" : "◦")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(Self.markdown(line.text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 13))
            .padding(.leading, level == 0 ? 0 : 15)
        }
    }

    /// Bold, italics, code and links in a line; the plain text when it isn't Markdown.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

// MARK: Small window

/// Checking, up to date, or the check failed: a small centred window like an alert.
private struct CompactPane: View {
    let phase: UpdatePhase
    let icon: NSImage
    let actions: UpdateActions

    private var title: String {
        switch phase {
        case .checking: "Checking for updates…"
        case .upToDate: "Keylog is up to date"
        default: "Couldn't check for updates"
        }
    }

    private var message: String {
        switch phase {
        case .checking: "Asking GitHub for the newest version."
        case .upToDate(let version): "You have Keylog \(version), the newest version."
        case .checkFailed(let message): message
        default: ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppIcon(image: icon)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 10)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            if case .checking = phase {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Checking")
                    .padding(.top, 14)
                wide("Cancel", action: actions.cancel)
                    .keyboardShortcut(.cancelAction)
                    .padding(.top, 14)
            } else {
                wide("OK", action: actions.close)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 16)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(UpdateLayout.padding)
        .frame(width: UpdateLayout.compactWidth)
    }

    private func wide(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }
}
