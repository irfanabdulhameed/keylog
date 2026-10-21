// Draws Keylog's app icon: a keyboard seen through a thermal camera, each key
// glowing with how hard it's used, Space white-hot.
//   swift scripts/make-icon.swift                  writes Resources/AppIcon.icns and AppIcon.png
//   swift scripts/make-icon.swift --preview <dir>  also renders it at 256, 64, 32 and 16 pt
import AppKit
import SwiftUI

/// Mixes two colours in sRGB; `amount` 0 is `a`, 1 is `b`.
func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ amount: Double) -> Color {
    Color(red: a.0 + (b.0 - a.0) * amount, green: a.1 + (b.1 - a.1) * amount, blue: a.2 + (b.2 - a.2) * amount)
}

/// Thermal scale, cold to white-hot.
func thermal(_ t: Double) -> (Double, Double, Double) {
    let stops: [(Double, (Double, Double, Double))] = [
        (0.0, (0.10, 0.18, 0.75)), (0.25, (0.0, 0.62, 0.95)), (0.45, (0.10, 0.85, 0.45)),
        (0.62, (1.0, 0.82, 0.10)), (0.78, (1.0, 0.45, 0.08)), (0.9, (0.95, 0.12, 0.18)), (1.0, (1.0, 0.92, 0.75)),
    ]
    let t = min(1, max(0, t))
    for i in 1..<stops.count where t <= stops[i].0 {
        let (t0, a) = stops[i - 1], (t1, b) = stops[i]
        let f = (t - t0) / (t1 - t0)
        return (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
    }
    return (1, 1, 1)
}

/// A keycap lit from inside by its own heat: a dark body, a glowing top with a
/// hot centre and a glassy sheen, and light spilling onto the desk below.
struct GlowKey: View {
    var heat: Double
    var width: CGFloat
    var height: CGFloat = 132
    /// The hottest key burns white in the middle and orange at its ends.
    var whiteHot = false
    static let orange = Color(red: 1, green: 0.42, blue: 0.1)
    static let yellow = Color(red: 1, green: 0.82, blue: 0.25)

    var body: some View {
        let rgb = whiteHot ? (1.0, 0.55, 0.15) : thermal(heat)
        let color = Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        let top: AnyShapeStyle = whiteHot
            ? AnyShapeStyle(LinearGradient(colors: [Self.orange, Self.yellow, .white, Self.yellow, Self.orange],
                                           startPoint: .leading, endPoint: .trailing))
            : AnyShapeStyle(RadialGradient(colors: [mix(rgb, (1, 1, 1), 0.45), color, mix(rgb, (0, 0, 0), 0.15)],
                                           center: UnitPoint(x: 0.5, y: 0.42), startRadius: 2,
                                           endRadius: max(width, height) * 0.62))
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(LinearGradient(colors: [mix(rgb, (0, 0, 0), 0.4), mix(rgb, (0, 0, 0), 0.72)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(top)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0)], startPoint: .top, endPoint: .center)))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(mix(rgb, (1, 1, 1), 0.6).opacity(0.75), lineWidth: 2))
                .padding(.horizontal, 10)
                .padding(.top, 7)
                .padding(.bottom, height * 0.17)
        }
        .frame(width: width, height: height)
        .shadow(color: color.opacity(0.6), radius: 14, y: 8)
        .shadow(color: color.opacity(0.25), radius: 34, y: 14)
    }
}

/// macOS icon grid: an 824 pt rounded square on a 1024 pt canvas.
struct ThermalIcon: View {
    var body: some View {
        let body = RoundedRectangle(cornerRadius: 185, style: .continuous)
        ZStack {
            ZStack {
                LinearGradient(colors: [Color(red: 0.085, green: 0.065, blue: 0.125), Color(red: 0.024, green: 0.02, blue: 0.035)],
                               startPoint: .top, endPoint: .bottom)
                // Heat pooling on the desk under the hottest keys, and a cool cast from above.
                Ellipse()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.45, blue: 0.12).opacity(0.32), .clear],
                                         center: .center, startRadius: 0, endRadius: 360))
                    .frame(width: 760, height: 300)
                    .offset(y: 205)
                Ellipse()
                    .fill(RadialGradient(colors: [Color(red: 0.25, green: 0.4, blue: 1).opacity(0.16), .clear],
                                         center: .center, startRadius: 0, endRadius: 420))
                    .frame(width: 820, height: 420)
                    .offset(x: -160, y: -300)
            }
            .clipShape(body)
            .overlay(
                body.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.03)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 3))
            .frame(width: 824, height: 824)
            .shadow(color: .black.opacity(0.3), radius: 18, y: 10)

            VStack(spacing: 18) {
                HStack(spacing: 18) {
                    ForEach([0.15, 0.4, 0.92, 0.6, 0.78], id: \.self) { GlowKey(heat: $0, width: 120, height: 124) }
                }
                .offset(x: -20)
                HStack(spacing: 18) {
                    ForEach([0.7, 0.55, 0.45, 0.35, 0.28], id: \.self) { GlowKey(heat: $0, width: 120, height: 124) }
                }
                .offset(x: 20)
                HStack(spacing: 18) {
                    GlowKey(heat: 0.5, width: 120, height: 124)
                    GlowKey(heat: 1, width: 420, height: 124, whiteHot: true)
                    GlowKey(heat: 0.24, width: 120, height: 124)
                }
            }
            .rotation3DEffect(.degrees(30), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.45)
            .offset(y: -18)
            // Keep every glow inside the icon's shape.
            .frame(width: 824, height: 824)
            .clipShape(body)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func png(size: CGFloat) -> Data {
    let renderer = ImageRenderer(content: ThermalIcon().scaleEffect(size / 1024).frame(width: size, height: size))
    renderer.scale = 1
    let rep = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

@MainActor
func main() throws {
    let arguments = CommandLine.arguments
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try png(size: CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try png(size: CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    let output = root.appendingPathComponent("Resources/AppIcon.icns")
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { throw NSError(domain: "iconutil", code: Int(iconutil.terminationStatus)) }
    try png(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))
    print("Wrote \(output.path)")

    if let flag = arguments.firstIndex(of: "--preview"), flag + 1 < arguments.count {
        let folder = URL(fileURLWithPath: arguments[flag + 1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for size in [256, 64, 32, 16] {
            try png(size: CGFloat(size * 2)).write(to: folder.appendingPathComponent("icon-\(size)@2x.png"))
        }
        print("Wrote previews to \(folder.path)")
    }
}

try MainActor.assumeIsolated { try main() }
