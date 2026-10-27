import SwiftUI

/// How pressed keys are filled. Chosen on the Customize Keyboard page. Most styles colour each
/// key from its own count. The thermal styles draw a heat field instead (`HeatField`), with
/// heat spreading from each pressed key's centre, the way a plotted keyboard heatmap does.
enum HeatStyle: String, CaseIterable, Identifiable {
    case solid
    case lit
    case ramp
    case thermal
    case thermalIntense
    case infrared
    case ember
    case neon
    case magma
    case glass
    case graphite
    case frost
    var id: Self { self }

    var title: String {
        switch self {
        case .solid: "Solid"
        case .lit: "Lit keycap"
        case .ramp: "Heat ramp"
        case .thermal: "Thermal camera"
        case .thermalIntense: "Thermal, intense"
        case .infrared: "Infrared"
        case .ember: "Ember glow"
        case .neon: "Neon"
        case .magma: "Magma"
        case .glass: "Glass"
        case .graphite: "Graphite"
        case .frost: "Frost"
        }
    }

    /// One line for the page's footer.
    var detail: String {
        switch self {
        case .solid: "One flat heat colour per key."
        case .lit: "Heat colours lit from the top, deeper at the bottom."
        case .ramp: "Each key runs from one step cooler to its own heat."
        case .thermal: "Heat spreads from every key you press and builds up where you type most."
        case .thermalIntense: "The thermal field pushed hotter: wider, redder, white where you type most."
        case .infrared: "Magenta at the edges of the heat, yellow where it builds up, blue at the hottest."
        case .ember: "Dark keys with their heat glowing up from underneath."
        case .neon: "Dark keys outlined in glowing heat colours."
        case .magma: "From deep purple through red to pale yellow."
        case .glass: "Tinted glass, clearer for quiet keys."
        case .graphite: "Neutral greys, stronger the more a key is used."
        case .frost: "A soft grey gradient with a lit top edge."
        }
    }

    var isNeutral: Bool { self == .graphite || self == .frost }

    /// The heat field's palette, for the styles drawn as a field.
    var field: HeatField.Palette? {
        switch self {
        case .thermal: HeatField.thermal
        case .thermalIntense: HeatField.intense
        case .infrared: HeatField.infrared
        default: nil
        }
    }

    /// The colour for a heat level from 0 to 1, for the bars beside the heatmap.
    func color(_ level: Double) -> Color {
        if let field { return field.color(level) }
        switch self {
        case .graphite, .frost: return Color.primary.opacity(0.1 + 0.82 * level)
        case .magma: return Self.magma(level)
        default: return Theme.heat(level)
        }
    }

    /// The Less to More legend.
    var legend: LinearGradient {
        if let field { return field.legend }
        return switch self {
        case .graphite, .frost:
            LinearGradient(colors: [color(0), color(1)], startPoint: .leading, endPoint: .trailing)
        case .magma:
            LinearGradient(colors: stride(from: 0.0, through: 1, by: 0.2).map(Self.magma), startPoint: .leading, endPoint: .trailing)
        default:
            Theme.heatGradient
        }
    }

    // MARK: Palettes

    private static let magmaStops: [(Double, Double, Double)] = [
        (0.09, 0.05, 0.20), (0.32, 0.07, 0.45), (0.55, 0.16, 0.51), (0.85, 0.28, 0.41), (0.99, 0.56, 0.38), (0.99, 0.92, 0.70),
    ]

    /// Magma, deep purple to pale yellow.
    static func magma(_ t: Double) -> Color {
        let t = min(1, max(0, t)) * Double(magmaStops.count - 1)
        let i = min(magmaStops.count - 2, Int(t))
        let f = t - Double(i)
        let (a, b) = (magmaStops[i], magmaStops[i + 1])
        return Color(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f)
    }
}

struct KeyboardHeatmap: View {
    let counts: [UInt16: Int]
    let total: Int
    let maxCount: Int
    var style = HeatStyle.solid
    var gap: CGFloat = 5
    /// Previews draw the keys without names, counts or hover.
    var showsLabels = true
    var interactive = true

    var body: some View {
        GeometryReader { geometry in
            let unit = (geometry.size.width + gap) / 15
            if let palette = style.field {
                // Plain keys, the heat over them, then names and counts on top.
                ZStack(alignment: .topLeading) {
                    layout(unit: unit, part: .base)
                    if let field = HeatField.image(counts: counts, maxCount: maxCount, palette: palette) {
                        Image(decorative: field, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: HeatField.size.width * unit, height: HeatField.size.height * unit)
                            .offset(x: -gap / 2, y: -gap / 2)
                            .allowsHitTesting(false)
                    }
                    layout(unit: unit, part: .labels)
                }
            } else {
                layout(unit: unit, part: .whole)
            }
        }
        .aspectRatio(15 / 5.72, contentMode: .fit)
    }

    private func layout(unit: CGFloat, part: KeyCapView.Part) -> some View {
        VStack(alignment: .leading, spacing: gap) {
            row(MacKeyboard.functionRow, unit: unit, height: unit * 0.72, part: part)
            ForEach(0..<MacKeyboard.rows.count, id: \.self) { index in
                row(MacKeyboard.rows[index], unit: unit, height: unit, part: part)
            }
            HStack(spacing: gap) {
                ForEach(MacKeyboard.bottomRow) { key(spec: $0, unit: unit, height: unit, part: part) }
                key(spec: KeySpec(code: 123, width: 1), unit: unit, height: unit * 0.5, part: part)
                    .frame(height: unit - gap, alignment: .bottom)
                VStack(spacing: gap / 2) {
                    key(spec: KeySpec(code: 126, width: 1), unit: unit, height: (unit - gap / 2) / 2 + gap / 2, part: part)
                    key(spec: KeySpec(code: 125, width: 1), unit: unit, height: (unit - gap / 2) / 2 + gap / 2, part: part)
                }
                key(spec: KeySpec(code: 124, width: 1), unit: unit, height: unit * 0.5, part: part)
                    .frame(height: unit - gap, alignment: .bottom)
            }
        }
    }

    private func row(_ specs: [KeySpec], unit: CGFloat, height: CGFloat, part: KeyCapView.Part) -> some View {
        HStack(spacing: gap) {
            ForEach(specs) { key(spec: $0, unit: unit, height: height, part: part) }
        }
    }

    private func key(spec: KeySpec, unit: CGFloat, height: CGFloat, part: KeyCapView.Part) -> some View {
        let count = counts[spec.code] ?? 0
        return KeyCapView(code: spec.code, count: count, total: total,
                          level: Theme.heatLevel(count, max: maxCount), align: spec.align,
                          fontSize: max(9, unit * 0.2), style: style, part: part,
                          radius: min(6, max(2, unit * 0.11)), showsLabels: showsLabels, interactive: interactive)
            .frame(width: spec.width * unit - gap, height: height - gap)
    }
}

struct KeyCapView: View {
    let code: UInt16
    let count: Int
    let total: Int
    let level: Double
    let align: Alignment
    let fontSize: CGFloat
    var style = HeatStyle.solid
    /// The thermal styles draw each key twice, under and over the heat field.
    var part = Part.whole
    var radius: CGFloat = 6
    var showsLabels = true
    var interactive = true
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Part {
        /// The fill, the names and the counts.
        case whole
        /// Only the fill, under the heat field.
        case base
        /// Only the names, counts and hover, over the heat field.
        case labels
    }

    var body: some View {
        let pressed = count > 0
        let active = interactive && part != .base
        ZStack(alignment: .topLeading) {
            if part != .labels { fill(pressed: pressed) }
            if showsLabels && part != .base {
                Text(KeyNames.name(code))
                    .font(.system(size: KeyNames.name(code).count > 1 ? fontSize * 0.8 : fontSize, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(pressed ? label : style.field != nil ? Color.white.opacity(0.6) : Color.secondary)
                    .shadow(color: pressed ? labelShadow : .clear, radius: 1.5)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
                if pressed {
                    Text(Format.compact(count))
                        .font(.system(size: max(8, fontSize * 0.62), weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(label.opacity(0.85))
                        .shadow(color: labelShadow, radius: 1.5)
                        .padding(.horizontal, 4)
                        .padding(.top, 3)
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(hovering ? Color.accentColor : part == .labels ? .clear : Color.primary.opacity(0.1),
                                    lineWidth: hovering ? 2 : 0.5))
        // Over the heat field the fill stays put underneath, so the key doesn't grow there.
        .scaleEffect(hovering && !reduceMotion && part == .whole ? 1.05 : 1)
        .zIndex(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { if active { hovering = $0 } }
        .help(!active ? ""
              : count > 0
              ? "\(KeyNames.full(code)): \(Format.count(count)) presses, \(Format.percent(count, of: total)) of all"
              : "\(KeyNames.full(code)): not pressed")
        .accessibilityElement()
        .accessibilityLabel("\(KeyNames.full(code)), \(count) presses")
        .accessibilityHidden(!active)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    /// Text on a pressed key: whichever reads on its fill.
    private var label: Color {
        switch style {
        case .ember, .neon, .thermal, .thermalIntense, .infrared: .white
        case .solid, .lit, .ramp: Theme.heatLabel(level)
        case .magma: level > 0.62 ? .black : .white
        case .glass: .primary
        // Past the middle the grey is strong: the background colour reads on it.
        case .graphite, .frost: level > 0.55 ? Color(nsColor: .windowBackgroundColor) : .primary
        }
    }

    /// A soft halo where the fill changes under the text.
    private var labelShadow: Color {
        switch style {
        case .thermal, .thermalIntense, .infrared: .black.opacity(0.6)
        case .neon: .black.opacity(0.5)
        default:
            .clear
        }
    }

    @ViewBuilder
    private func fill(pressed: Bool) -> some View {
        let heat = Theme.heat(level)
        if style.field != nil {
            // Plain keys, pressed or not: the heat field over them carries the colour.
            shape.fill(style == .infrared ? Color(white: 0.11) : scheme == .dark ? Color(white: 0.3) : Color(white: 0.45))
        } else if !pressed {
            shape.fill(Color.primary.opacity(0.06))
        } else {
            switch style {
            case .solid:
                shape.fill(heat)

            case .lit:
                shape.fill(LinearGradient(colors: [Color.white.opacity(0.3), .clear, Color.black.opacity(0.22)],
                                          startPoint: .top, endPoint: .bottom))
                    .background(shape.fill(heat))
                    .overlay(topEdge(0.35))

            case .ramp:
                shape.fill(LinearGradient(colors: [Theme.heat(max(0, level - 0.2)), heat],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))

            case .ember:
                shape.fill(Color(white: 0.11))
                    .overlay(shape.fill(EllipticalGradient(colors: [heat, heat.opacity(0.55), heat.opacity(0)],
                                                           center: UnitPoint(x: 0.5, y: 1.05),
                                                           startRadiusFraction: 0, endRadiusFraction: 0.95)
                        .opacity(0.45 + 0.55 * level)))
                    .overlay(shape.inset(by: 0.5).stroke(heat.opacity(0.3 + 0.5 * level), lineWidth: 1))

            case .neon:
                shape.fill(Color(white: 0.09))
                    .overlay(shape.fill(EllipticalGradient(colors: [heat.opacity(0.08 + 0.3 * level), .clear],
                                                           center: .center, startRadiusFraction: 0, endRadiusFraction: 0.8)))
                    .overlay(shape.inset(by: 1).stroke(heat, lineWidth: 1.5)
                        .shadow(color: heat.opacity(0.5 + 0.5 * level), radius: 1.5 + 3 * level))

            case .thermal, .thermalIntense, .infrared:
                EmptyView()

            case .magma:
                shape.fill(LinearGradient(colors: [HeatStyle.magma(min(1, level + 0.06)), HeatStyle.magma(max(0, level - 0.06))],
                                          startPoint: .top, endPoint: .bottom))

            case .glass:
                shape.fill(heat.opacity(0.22 + 0.5 * level))
                    .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.4), .white.opacity(0.06), .clear],
                                                       startPoint: .top, endPoint: .center)))
                    .overlay(topEdge(0.55))
                    .overlay(shape.inset(by: 0.5).stroke(heat.opacity(0.5), lineWidth: 0.75))

            case .graphite:
                shape.fill(style.color(level))

            case .frost:
                shape.fill(LinearGradient(colors: [style.color(min(1, level + 0.14)), style.color(max(0, level - 0.12))],
                                          startPoint: .top, endPoint: .bottom))
                    .overlay(topEdge(0.3))
            }
        }
    }

    /// A thin light along the top edge, fading out by the middle.
    private func topEdge(_ opacity: Double) -> some View {
        shape.inset(by: 0.75).stroke(Color.white.opacity(opacity), lineWidth: 1)
            .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
    }
}
