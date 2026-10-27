import SwiftUI

/// One bar of a `BarChart`: its stacked segments, bottom first.
struct BarColumn: Identifiable {
    struct Segment {
        let value: Double
        let color: Color
    }

    let id: Int
    var segments: [Segment]
    /// Spoken by VoiceOver, and shown as a help tag when the chart asks for one.
    var label: String
    /// A faint stub instead of a bar: no data yet, not a zero.
    var placeholder = false

    var total: Double { segments.reduce(0) { $0 + $1.value } }
}

/// Stacked bars drawn as separate rounded segments with gaps between them, no y-axis.
/// Hovering dims the other bars, outlines the bar and shows `tooltip` beside it.
struct BarChart<Tooltip: View>: View {
    let columns: [BarColumn]
    @Binding var hovered: Int?
    /// First and last slot names, printed under the ends of the chart.
    var edgeLabels: (String, String)?
    var gap: CGFloat = 2
    var maxBarWidth: CGFloat = 20
    var labelFont: Font = .callout
    var helpTags = false
    var onSelect: ((Int) -> Void)?
    @ViewBuilder var tooltip: (Int) -> Tooltip

    @State private var grown = Snapshot.isRendering
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Room above the tallest bar for the hover outline.
    private let headroom: CGFloat = 5

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geometry in
                let pitch = geometry.size.width / CGFloat(max(1, columns.count))
                let width = min(maxBarWidth, max(2, (pitch * 0.6).rounded()))
                let peak = columns.map(\.total).max() ?? 0
                let pieces = columns.map { $0.segments.filter { $0.value > 0 }.count }.max() ?? 1
                let usable = max(0, geometry.size.height - headroom - gap * CGFloat(max(0, pieces - 1)))
                let scale = peak > 0 ? usable / peak : 0
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(columns) { column in
                            bar(column, width: width, scale: scale)
                                .frame(width: pitch, height: geometry.size.height, alignment: .bottom)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            let index = min(columns.count - 1, max(0, Int(location.x / pitch)))
                            hovered = columns.indices.contains(index) ? columns[index].id : nil
                        case .ended:
                            hovered = nil
                        }
                    }
                    .onTapGesture {
                        if let hovered { onSelect?(hovered) }
                    }

                    if let hovered, let index = columns.firstIndex(where: { $0.id == hovered }) {
                        let center = pitch * (CGFloat(index) + 0.5)
                        tooltip(hovered)
                            .fixedSize()
                            // Left of the bar, or right of it when there's no room on the left.
                            .alignmentGuide(.leading) { d in
                                let left = center - width / 2 - 12 - d.width
                                let x = left >= 0 ? left : min(center + width / 2 + 12, geometry.size.width - d.width)
                                return -x
                            }
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
            }
            if let edgeLabels {
                HStack {
                    Text(edgeLabels.0)
                    Spacer()
                    Text(edgeLabels.1)
                }
                .font(labelFont)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            if reduceMotion { grown = true } else { withAnimation(.smooth(duration: 0.6)) { grown = true } }
        }
    }

    private func bar(_ column: BarColumn, width: CGFloat, scale: CGFloat) -> some View {
        let radius = min(3.5, width / 2)
        let isHovered = hovered == column.id
        let pieces = column.segments.filter { $0.value > 0 }
        return VStack(spacing: gap) {
            if column.placeholder {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: width, height: 2)
            } else {
                ForEach(Array(pieces.enumerated().reversed()), id: \.offset) { _, segment in
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(segment.color)
                        .frame(width: width, height: max(2, (segment.value * scale).rounded()))
                }
            }
        }
        // Grow up from the baseline when the chart first appears.
        .mask(alignment: .bottom) {
            Rectangle().scaleEffect(y: grown ? 1 : 0.001, anchor: .bottom)
        }
        .overlay {
            if isHovered {
                RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.5), lineWidth: 1.5)
                    .padding(-4)
                    .transition(.opacity)
            }
        }
        .opacity(hovered == nil || isHovered ? 1 : 0.35)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: column.total)
        .help(helpTags ? column.label : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.label)
        .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
        .accessibilityAction { onSelect?(column.id) }
    }
}

/// The card shown beside a hovered bar: slot name and total, then one row per part.
struct BarTooltip: View {
    struct Row: Identifiable {
        let name: String
        let color: Color
        let value: String
        var id: String { name }
    }

    let title: String
    let total: String
    var rows: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 24) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(total).fontWeight(.semibold).monospacedDigit()
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(row.color)
                        .frame(width: 9, height: 9)
                    Text(row.name)
                    Spacer(minLength: 16)
                    Text(row.value).monospacedDigit()
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 150, alignment: .leading)
        .background(Theme.tooltip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

extension BarChart where Tooltip == EmptyView {
    init(columns: [BarColumn], hovered: Binding<Int?>, edgeLabels: (String, String)? = nil,
         gap: CGFloat = 2, maxBarWidth: CGFloat = 20, labelFont: Font = .callout, helpTags: Bool = false,
         onSelect: ((Int) -> Void)? = nil) {
        self.init(columns: columns, hovered: hovered, edgeLabels: edgeLabels, gap: gap, maxBarWidth: maxBarWidth,
                  labelFont: labelFont, helpTags: helpTags, onSelect: onSelect) { _ in EmptyView() }
    }
}
