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

/// A key glowing with its own heat.
struct GlowKey: View {
    var heat: Double
    var width: CGFloat
    var height: CGFloat = 122

    var body: some View {
        let rgb = thermal(heat)
        let color = Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(RadialGradient(colors: [mix(rgb, (1, 1, 1), 0.3), color, mix(rgb, (0, 0, 0), 0.3)],
                                 center: .center, startRadius: 4, endRadius: max(width, height) * 0.75))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(mix(rgb, (1, 1, 1), 0.55).opacity(0.9), lineWidth: 3))
            .frame(width: width, height: height)
            .shadow(color: color.opacity(0.75), radius: 9)
            .shadow(color: color.opacity(0.35), radius: 26)
    }
}

/// macOS icon grid: an 824 pt rounded square on a 1024 pt canvas.
struct ThermalIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.09, green: 0.07, blue: 0.13), Color(red: 0.02, green: 0.02, blue: 0.04)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 3))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            VStack(spacing: 22) {
                HStack(spacing: 22) {
                    ForEach([0.22, 0.42, 0.86, 0.6, 0.5], id: \.self) { GlowKey(heat: $0, width: 122) }
                }
                .offset(x: -26)
                HStack(spacing: 22) {
                    ForEach([0.74, 0.55, 0.35, 0.28, 0.12], id: \.self) { GlowKey(heat: $0, width: 122) }
                }
                .offset(x: 26)
                GlowKey(heat: 1.0, width: 560)
            }
            .rotation3DEffect(.degrees(26), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.4)
            .offset(y: 10)
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
