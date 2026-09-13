import SwiftUI

extension Color {
    /// Creates a Color from a hex string like "#5FCB82" or "5FCB82".
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    /// Creates a Color from HSL values (h: 0-360, s/l: 0-100), matching the
    /// design system's hslStr() convention (CSS hsl(), distinct from SwiftUI's HSB init).
    init(h: Double, s: Double, l: Double) {
        let s = max(0, min(100, s)) / 100
        let l = max(0, min(100, l)) / 100
        let c = (1 - abs(2 * l - 1)) * s
        let hPrime = h.truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let rgb: (Double, Double, Double)
        switch hPrime {
        case 0..<1: rgb = (c, x, 0)
        case 1..<2: rgb = (x, c, 0)
        case 2..<3: rgb = (0, c, x)
        case 3..<4: rgb = (0, x, c)
        case 4..<5: rgb = (x, 0, c)
        default:    rgb = (c, 0, x)
        }
        self.init(red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m)
    }
}
