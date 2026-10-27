import CoreGraphics
import SwiftUI

/// The heat field behind the thermal styles, drawn the way a heatmap plot draws one: every
/// pressed key adds a round soft spot of heat at its own centre, the same size on every key,
/// weighted by how much it was used. Spots that overlap add up, so neighbouring busy keys
/// merge into a ridge; heat fades to nothing within about a key, so keys far from any pressed
/// key stay plain. The sum is scaled to its hottest point and coloured through a palette.
enum HeatField {
    struct Palette {
        /// Colour stops from no heat (0) to the hottest point (1).
        let stops: [(Double, Double, Double, Double)]
        /// How far each key's heat spreads, in key widths.
        let spread: Double
        /// Below 1 more of the field reads hot.
        let gamma: Double
        /// The field's opacity where it's fully on.
        let opacity: Double
        /// Below this the field is clear, so keys far from the heat stay plain.
        let floor: Double
        /// Where the field reaches full opacity, fading in from `floor`.
        let fadeIn: Double

        func rgb(_ v: Double) -> (Double, Double, Double) {
            let v = min(1, max(0, v))
            for i in 1..<stops.count where v <= stops[i].0 {
                let (a, b) = (stops[i - 1], stops[i])
                let f = (v - a.0) / max(0.0001, b.0 - a.0)
                return (a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f, a.3 + (b.3 - a.3) * f)
            }
            let last = stops[stops.count - 1]
            return (last.1, last.2, last.3)
        }

        func color(_ v: Double) -> Color {
            let (r, g, b) = rgb(v)
            return Color(red: r, green: g, blue: b)
        }

        var legend: LinearGradient {
            LinearGradient(stops: stops.map { Gradient.Stop(color: Color(red: $0.1, green: $0.2, blue: $0.3), location: $0.0) },
                           startPoint: .leading, endPoint: .trailing)
        }
    }

    /// Pale lavender through cyan, green and yellow to red, like a plotted keyboard heatmap.
    static let thermal = Palette(stops: [
        (0.00, 0.80, 0.80, 1.00), (0.18, 0.55, 0.78, 1.00), (0.32, 0.25, 0.85, 0.95), (0.45, 0.20, 0.78, 0.62),
        (0.58, 0.62, 0.86, 0.25), (0.68, 1.00, 0.88, 0.15), (0.82, 1.00, 0.55, 0.08), (1.00, 0.93, 0.10, 0.08),
    ], spread: 0.45, gamma: 1, opacity: 0.82, floor: 0.03, fadeIn: 0.2)

    /// The same scale pushed hotter: wider spots, more of the field in the reds, and the
    /// busiest keys burning white.
    static let intense = Palette(stops: [
        (0.00, 0.45, 0.55, 1.00), (0.20, 0.15, 0.75, 1.00), (0.36, 0.10, 0.85, 0.55), (0.50, 0.70, 0.92, 0.12),
        (0.62, 1.00, 0.85, 0.05), (0.76, 1.00, 0.45, 0.02), (0.90, 0.95, 0.08, 0.06), (1.00, 1.00, 0.88, 0.78),
    ], spread: 0.48, gamma: 0.8, opacity: 0.95, floor: 0.1, fadeIn: 0.26)

    /// A magenta rim, orange and yellow where heat builds up, and blue to pale lilac at the hottest.
    static let infrared = Palette(stops: [
        (0.00, 0.85, 0.20, 0.50), (0.14, 0.88, 0.22, 0.50), (0.30, 0.95, 0.36, 0.30), (0.46, 0.97, 0.58, 0.20),
        (0.62, 0.98, 0.85, 0.32), (0.78, 0.45, 0.55, 0.95), (0.90, 0.33, 0.45, 0.93), (1.00, 0.82, 0.85, 1.00),
    ], spread: 0.42, gamma: 0.9, opacity: 0.95, floor: 0.12, fadeIn: 0.26)

    /// Field pixels per key width.
    static let resolution = 16.0
    /// The keyboard is 15 keys wide and 5.72 tall.
    static let size = CGSize(width: 15, height: 5.72)

    /// Each key's centre, in key widths from the top left, following `MacKeyboard`.
    static let centres: [UInt16: CGPoint] = {
        var map: [UInt16: CGPoint] = [:]
        func walk(_ specs: [KeySpec], y: Double) {
            var x = 0.0
            for spec in specs {
                map[spec.code] = CGPoint(x: x + spec.width / 2, y: y)
                x += spec.width
            }
        }
        walk(MacKeyboard.functionRow, y: 0.36)
        for (index, row) in MacKeyboard.rows.enumerated() { walk(row, y: 0.72 + Double(index) + 0.5) }
        let bottom = 0.72 + Double(MacKeyboard.rows.count)
        walk(MacKeyboard.bottomRow, y: bottom + 0.5)
        map[123] = CGPoint(x: 12.5, y: bottom + 0.75)
        map[126] = CGPoint(x: 13.5, y: bottom + 0.25)
        map[125] = CGPoint(x: 13.5, y: bottom + 0.75)
        map[124] = CGPoint(x: 14.5, y: bottom + 0.75)
        return map
    }()

    /// The field as an image covering the whole keyboard, or nil when nothing was pressed.
    static func image(counts: [UInt16: Int], maxCount: Int, palette: Palette) -> CGImage? {
        guard maxCount > 0 else { return nil }
        // Square-root weights: busy keys lead, and quieter ones still leave a trace.
        let sources: [(Double, Double, Double)] = counts.compactMap { code, count -> (Double, Double, Double)? in
            guard count > 0, let centre = centres[code] else { return nil }
            return (Double(centre.x), Double(centre.y), (Double(count) / Double(maxCount)).squareRoot())
        }
        guard !sources.isEmpty else { return nil }
        let width = Int(size.width * resolution), height = Int((size.height * resolution).rounded())
        let twoSigmaSquared = 2 * palette.spread * palette.spread
        let reach = 9 * palette.spread * palette.spread
        var field = [Double](repeating: 0, count: width * height)
        var peak = 0.0
        for py in 0..<height {
            let y = (Double(py) + 0.5) / resolution
            for px in 0..<width {
                let x = (Double(px) + 0.5) / resolution
                var sum = 0.0
                for (cx, cy, weight) in sources {
                    let d = (x - cx) * (x - cx) + (y - cy) * (y - cy)
                    if d < reach { sum += weight * exp(-d / twoSigmaSquared) }
                }
                field[py * width + px] = sum
                peak = max(peak, sum)
            }
        }
        guard peak > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<field.count {
            let v = pow(field[i] / peak, palette.gamma)
            let t = min(1, max(0, (v - palette.floor) / (palette.fadeIn - palette.floor)))
            let alpha = t * t * (3 - 2 * t) * palette.opacity
            guard alpha > 0.004 else { continue }
            let (r, g, b) = palette.rgb(v)
            // Premultiplied, as the bitmap context expects.
            pixels[i * 4] = UInt8(min(255, r * alpha * 255))
            pixels[i * 4 + 1] = UInt8(min(255, g * alpha * 255))
            pixels[i * 4 + 2] = UInt8(min(255, b * alpha * 255))
            pixels[i * 4 + 3] = UInt8(min(255, alpha * 255))
        }
        return pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
