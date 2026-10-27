import SwiftUI

/// How pressed keys are filled. Chosen on the Customize Keyboard page. Every effect is drawn
/// inside its own key from that key's count alone: no key borrows colour from its neighbours,
/// and a key that was never pressed stays plain.
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
        case .thermal: "Each key is warm in the middle and cools towards its edges."
        case .thermalIntense: "A white-hot core in busy keys, cooling fast to deep blue."
        case .infrared: "A soft blob in every key: blue core, yellow ring, red rim. Bigger and brighter the more it's used."
        case .ember: "Dark keys with their heat glowing up from underneath."
        case .neon: "Dark keys outlined in glowing heat colours."
        case .magma: "From deep purple through red to pale yellow."
        case .glass: "Tinted glass, clearer for quiet keys."
        case .graphite: "Neutral greys, stronger the more a key is used."
        case .frost: "A soft grey gradient with a lit top edge."
        }
    }

    var isNeutral: Bool { self == .graphite || self == .frost }

    /// The colour for a heat level from 0 to 1, for the bars beside the heatmap.
    func color(_ level: Double) -> Color {
        switch self {
        case .graphite, .frost: Color.primary.opacity(0.1 + 0.82 * level)
        case .magma: Self.magma(level)
        default: Theme.heat(level)
        }
    }

    /// The Less to More legend.
    var legend: LinearGradient {
        switch self {
        case .graphite, .frost:
            LinearGradient(colors: [color(0), color(1)], startPoint: .leading, endPoint: .trailing)
        case .magma:
            LinearGradient(colors: stride(from: 0.0, through: 1, by: 0.2).map(Self.magma), startPoint: .leading, endPoint: .trailing)
        case .infrared:
            LinearGradient(colors: [Color(white: 0.45), Self.infraredBlue, Self.infraredYellow, Self.infraredOrange, Self.infraredRim],
                           startPoint: .leading, endPoint: .trailing)
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

    static let infraredCore = Color(red: 0.80, green: 0.84, blue: 1.00)
    static let infraredBlue = Color(red: 0.33, green: 0.45, blue: 0.93)
    static let infraredYellow = Color(red: 0.98, green: 0.85, blue: 0.32)
    static let infraredOrange = Color(red: 0.97, green: 0.55, blue: 0.20)
    static let infraredRim = Color(red: 0.88, green: 0.20, blue: 0.48)
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
            VStack(alignment: .leading, spacing: gap) {
                row(MacKeyboard.functionRow, unit: unit, height: unit * 0.72)
                ForEach(0..<MacKeyboard.rows.count, id: \.self) { index in
                    row(MacKeyboard.rows[index], unit: unit, height: unit)
                }
                HStack(spacing: gap) {
                    ForEach(MacKeyboard.bottomRow) { key(spec: $0, unit: unit, height: unit) }
                    key(spec: KeySpec(code: 123, width: 1), unit: unit, height: unit * 0.5)
                        .frame(height: unit - gap, alignment: .bottom)
                    VStack(spacing: gap / 2) {
                        key(spec: KeySpec(code: 126, width: 1), unit: unit, height: (unit - gap / 2) / 2 + gap / 2)
                        key(spec: KeySpec(code: 125, width: 1), unit: unit, height: (unit - gap / 2) / 2 + gap / 2)
                    }
                    key(spec: KeySpec(code: 124, width: 1), unit: unit, height: unit * 0.5)
                        .frame(height: unit - gap, alignment: .bottom)
                }
            }
        }
        .aspectRatio(15 / 5.72, contentMode: .fit)
    }

    private func row(_ specs: [KeySpec], unit: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(specs) { key(spec: $0, unit: unit, height: height) }
        }
    }

    private func key(spec: KeySpec, unit: CGFloat, height: CGFloat) -> some View {
        let count = counts[spec.code] ?? 0
        return KeyCapView(code: spec.code, count: count, total: total,
                          level: Theme.heatLevel(count, max: maxCount), align: spec.align,
                          fontSize: max(9, unit * 0.2), style: style,
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
    var radius: CGFloat = 6
    var showsLabels = true
    var interactive = true
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = count > 0
        ZStack(alignment: .topLeading) {
            fill(pressed: pressed)
            if showsLabels {
                Text(KeyNames.name(code))
                    .font(.system(size: KeyNames.name(code).count > 1 ? fontSize * 0.8 : fontSize, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(pressed ? label : Color.secondary)
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
        .overlay(shape.strokeBorder(hovering ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: hovering ? 2 : 0.5))
        .scaleEffect(hovering && !reduceMotion ? 1.05 : 1)
        .zIndex(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { if interactive { hovering = $0 } }
        .help(!interactive ? ""
              : count > 0
              ? "\(KeyNames.full(code)): \(Format.count(count)) presses, \(Format.percent(count, of: total)) of all"
              : "\(KeyNames.full(code)): not pressed")
        .accessibilityElement()
        .accessibilityLabel("\(KeyNames.full(code)), \(count) presses")
        .accessibilityHidden(!interactive)
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    /// Text on a pressed key: whichever reads on its fill.
    private var label: Color {
        switch style {
        case .ember, .neon, .infrared: .white
        case .solid, .lit, .ramp, .thermal: Theme.heatLabel(level)
        case .thermalIntense: level > 0.82 ? .black : Theme.heatLabel(level)
        case .magma: level > 0.62 ? .black : .white
        case .glass: .primary
        // Past the middle the grey is strong: the background colour reads on it.
        case .graphite, .frost: level > 0.55 ? Color(nsColor: .windowBackgroundColor) : .primary
        }
    }

    /// A soft halo where the fill changes under the text.
    private var labelShadow: Color {
        switch style {
        case .thermal, .thermalIntense, .infrared, .neon:
            label == .black ? .white.opacity(0.35) : .black.opacity(0.5)
        default:
            .clear
        }
    }

    @ViewBuilder
    private func fill(pressed: Bool) -> some View {
        let heat = Theme.heat(level)
        if !pressed {
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

            case .thermal:
                // Warm in the middle, cooling to the key's edges.
                shape.fill(EllipticalGradient(colors: [heat, Theme.heat(level * 0.6), Theme.heat(level * 0.3)],
                                              center: .center, startRadiusFraction: 0, endRadiusFraction: 0.72))

            case .thermalIntense:
                shape.fill(EllipticalGradient(
                    stops: [.init(color: Theme.heat(min(1, level + 0.1)), location: 0),
                            .init(color: heat, location: 0.3),
                            .init(color: Theme.heat(level * 0.45), location: 0.62),
                            .init(color: Theme.heat(0), location: 1)],
                    center: .center, startRadiusFraction: 0, endRadiusFraction: 0.7))
                    .saturation(1.3)
                    // The busiest keys burn white in the middle.
                    .overlay(shape.fill(EllipticalGradient(colors: [.white.opacity(max(0, level - 0.72) * 2.6), .clear],
                                                           center: .center, startRadiusFraction: 0, endRadiusFraction: 0.32)))

            case .infrared:
                // A blob sized by use: blue core, yellow ring, a red-magenta rim, then the dark key.
                shape.fill(Color(white: 0.08))
                    .overlay(shape.fill(EllipticalGradient(
                        stops: [.init(color: HeatStyle.infraredCore, location: 0),
                                .init(color: HeatStyle.infraredBlue, location: 0.16),
                                .init(color: HeatStyle.infraredBlue.opacity(0.9), location: 0.26),
                                .init(color: HeatStyle.infraredYellow, location: 0.46),
                                .init(color: HeatStyle.infraredOrange, location: 0.64),
                                .init(color: HeatStyle.infraredRim.opacity(0.85), location: 0.8),
                                .init(color: HeatStyle.infraredRim.opacity(0), location: 1)],
                        // 0.5 reaches the key's edge: even the hottest blob leaves a dark margin, so its
                        // rim fades into the key, and quiet keys get a small one.
                        center: .center, startRadiusFraction: 0, endRadiusFraction: 0.3 + 0.2 * level))
                        .saturation(0.25 + 0.75 * level)
                        .opacity(0.55 + 0.45 * level))

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
