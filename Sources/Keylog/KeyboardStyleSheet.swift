import SwiftUI

/// The Customize Keyboard page: every heatmap style as a live preview, three across.
///
/// A click on a preview, or the arrow keys, applies that style at once, so the heatmap behind
/// the page changes as you choose. Done, Return or Esc closes the page.
struct KeyboardStyleSheet: View {
    let counts: [UInt16: Int]
    @Binding var style: HeatStyle
    var done: () -> Void
    @FocusState private var gridFocused: Bool

    private static let columns = 3

    var body: some View {
        let sample = counts.values.reduce(0, +) == 0
        let shown = sample ? Self.sampleCounts : counts
        let total = shown.values.reduce(0, +)
        let peak = shown.values.max() ?? 0
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Customize Keyboard")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(sample ? "Previews show sample typing until you type in this period."
                            : "Previews use the keys you pressed in this period.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: Self.columns), spacing: 16) {
                        ForEach(HeatStyle.allCases) { item in
                            StyleTile(style: item, selected: item == style, focused: gridFocused && item == style,
                                      counts: shown, total: total, peak: peak) { style = item }
                                .id(item)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
                }
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .onKeyPress(.leftArrow) { move(-1) }
                .onKeyPress(.rightArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-Self.columns) }
                .onKeyPress(.downArrow) { move(Self.columns) }
                .onChange(of: style) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(style) } }
            }

            Divider()
            HStack(spacing: 12) {
                Text(style.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 900, height: 660)
        .onAppear { gridFocused = true }
        .onExitCommand(perform: done)
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let all = HeatStyle.allCases
        guard let index = all.firstIndex(of: style) else { return .ignored }
        let next = index + step
        guard all.indices.contains(next) else { return .handled }
        style = all[next]
        return .handled
    }

    /// Typical English typing, for previews when nothing has been typed in the period.
    static let sampleCounts: [UInt16: Int] = [
        49: 180, 14: 127, 17: 91, 0: 82, 31: 75, 34: 70, 45: 67, 1: 63, 4: 61, 15: 60, 2: 43, 37: 40,
        8: 28, 32: 28, 46: 24, 13: 24, 3: 22, 5: 20, 16: 20, 35: 19, 11: 15, 9: 10, 40: 8, 38: 2,
        7: 2, 12: 1, 6: 1, 51: 40, 36: 15, 56: 20, 43: 12, 47: 10, 55: 15, 48: 6, 18: 4, 19: 3,
    ]
}

/// One preview: the keyboard in that style, its name, and a check when it's the chosen one.
private struct StyleTile: View {
    let style: HeatStyle
    let selected: Bool
    let focused: Bool
    let counts: [UInt16: Int]
    let total: Int
    let peak: Int
    let choose: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 9) {
                KeyboardHeatmap(counts: counts, total: total, maxCount: peak, style: style,
                                gap: 2, showsLabels: false, interactive: false)
                    .padding(10)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 0.5))
                HStack(spacing: 6) {
                    Text(style.title).font(.callout.weight(.medium))
                    if style.isNeutral {
                        Text("Neutral")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 2)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.1) : hovering ? Color.primary.opacity(0.05) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.2 : 0.08),
                              lineWidth: selected ? 2 : 1))
            .overlay {
                // The keyboard focus ring, around the chosen preview while the grid has focus.
                if focused {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 3)
                        .padding(-3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(TileButtonStyle(reduceMotion: reduceMotion))
        .focusable(false)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selected)
        .help(style.detail)
        .accessibilityLabel(style.title + (style.isNeutral ? ", neutral" : ""))
        .accessibilityHint(style.detail)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Sinks a little while pressed; with Reduce motion it only dims.
private struct TileButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.8 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
