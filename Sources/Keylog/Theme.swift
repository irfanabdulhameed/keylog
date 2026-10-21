import AppKit
import KeylogCore
import SwiftUI

/// Colours, names and the heat scale shared by every view.
enum Theme {
    static func color(_ group: KeyGroup) -> Color {
        switch group {
        case .letters: .blue
        case .numbers: .green
        case .special: .orange
        case .space: .purple
        case .other: .gray
        }
    }

    static func name(_ group: KeyGroup) -> String {
        switch group {
        case .letters: "Letters"
        case .numbers: "Numbers"
        case .special: "Special"
        case .space: "Space"
        case .other: "Other"
        }
    }

    /// Thermal scale stops, cold to hot: deep blue, blue, cyan, green, yellow, orange, red.
    private static let heatStops: [(Double, (Double, Double, Double))] = [
        (0.00, (0.12, 0.23, 0.54)),
        (0.18, (0.15, 0.39, 0.92)),
        (0.36, (0.02, 0.71, 0.83)),
        (0.54, (0.13, 0.77, 0.37)),
        (0.70, (0.92, 0.70, 0.03)),
        (0.85, (0.98, 0.45, 0.09)),
        (1.00, (0.86, 0.15, 0.15)),
    ]

    private static func heatRGB(_ t: Double) -> (Double, Double, Double) {
        let t = min(1, max(0, t))
        for i in 1..<heatStops.count where t <= heatStops[i].0 {
            let (t0, a) = heatStops[i - 1], (t1, b) = heatStops[i]
            let f = (t - t0) / (t1 - t0)
            return (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f, a.2 + (b.2 - a.2) * f)
        }
        return heatStops.last!.1
    }

    /// Heat colour for `t` from 0 (cold) to 1 (hottest).
    static func heat(_ t: Double) -> Color {
        let (r, g, b) = heatRGB(t)
        return Color(red: r, green: g, blue: b)
    }

    /// Black or white, whichever reads better on the heat colour for `t`.
    static func heatLabel(_ t: Double) -> Color {
        let (r, g, b) = heatRGB(t)
        func linear(_ c: Double) -> Double { c <= 0.039_28 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance > 0.22 ? .black : .white
    }

    /// Log scale, so Space and E don't wash out every other key.
    static func heatLevel(_ count: Int, max: Int) -> Double {
        guard count > 0, max > 0 else { return 0 }
        return log(Double(count) + 1) / log(Double(max) + 1)
    }

    static let heatGradient = LinearGradient(
        stops: heatStops.map { Gradient.Stop(color: heat($0.0), location: $0.0) },
        startPoint: .leading, endPoint: .trailing)

    /// Card background used across the dashboard.
    static let card = Color(nsColor: .controlBackgroundColor)
    static let cardBorder = Color(nsColor: .separatorColor).opacity(0.6)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 0.5))
    }
}

/// Key names for chips, tooltips and the keyboard drawing.
enum KeyNames {
    private static let translator = KeyTranslator()

    /// Keys whose label doesn't come from the keyboard layout.
    private static let fixed: [UInt16: String] = [
        53: "esc", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        51: "delete", 48: "tab", 57: "caps lock", 36: "return", 76: "enter", 49: "space",
        56: "shift", 60: "shift", 63: "fn", 59: "control", 62: "control", 58: "option", 61: "option",
        55: "command", 54: "command", 123: "←", 124: "→", 125: "↓", 126: "↑",
        117: "⌦", 115: "home", 119: "end", 116: "page up", 121: "page down", 114: "help", 71: "clear",
    ]

    /// Short symbols for chips, where a Mac keyboard prints one.
    private static let symbols: [UInt16: String] = [
        51: "⌫", 48: "⇥", 36: "⏎", 76: "⌤", 56: "⇧", 60: "⇧", 55: "⌘", 54: "⌘", 58: "⌥", 61: "⌥",
        59: "⌃", 62: "⌃", 57: "⇪", 117: "⌦",
    ]

    /// US labels, used when the current layout gives nothing.
    private static let us: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
    ]

    /// What's printed on the key: "E", "7", "return", "⇧ shift" style names.
    static func name(_ code: UInt16) -> String {
        if let name = fixed[code] { return name }
        if let character = translator.character(for: code), !character.isWhitespace,
           character.unicodeScalars.first.map({ $0.properties.generalCategory != .control }) ?? false {
            return String(character).uppercased()
        }
        return us[code] ?? "key \(code)"
    }

    /// Compact label for chips: a symbol where one exists, otherwise the name.
    static func chip(_ code: UInt16) -> String {
        if code == 49 { return "Space" }
        return symbols[code] ?? name(code)
    }

    /// Left or right, for modifiers that come in pairs.
    static func full(_ code: UInt16) -> String {
        switch code {
        case 56, 59, 58, 55: "left \(name(code))"
        case 60, 62, 61, 54: "right \(name(code))"
        default: name(code)
        }
    }
}

enum Format {
    private static let integer: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    /// 12438 → "12,438", using the Mac's grouping separator.
    static func count(_ value: Int) -> String {
        integer.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 12438 → "12.4k", 1_250_000 → "1.25M".
    static func compact(_ value: Int) -> String {
        let v = Double(value)
        switch abs(v) {
        case ..<1000: return "\(value)"
        case ..<10_000: return String(format: "%.1fk", v / 1000).replacingOccurrences(of: ".0k", with: "k")
        case ..<1_000_000: return String(format: "%.0fk", v / 1000)
        case ..<10_000_000: return String(format: "%.2fM", v / 1_000_000)
        default: return String(format: "%.1fM", v / 1_000_000)
        }
    }

    /// Millimetres as cm, m or km, whichever reads best.
    static func distance(mm: Double) -> String {
        let metres = mm / 1000
        switch metres {
        case ..<1: return "\(Int((mm / 10).rounded())) cm"
        case ..<10: return String(format: "%.1f m", metres)
        case ..<1000: return "\(Int(metres.rounded())) m"
        default: return String(format: "%.2f km", metres / 1000)
        }
    }

    static func percent(_ part: Int, of total: Int) -> String {
        guard total > 0 else { return "0%" }
        let value = Double(part) / Double(total) * 100
        return value < 10 && value > 0 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }

    /// 197 minutes → "3h 17m".
    static func duration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
