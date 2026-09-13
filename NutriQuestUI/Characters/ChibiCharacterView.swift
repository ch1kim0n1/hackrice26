import SwiftUI

/// Facial expression for the chibi mascot.
public enum ChibiExpression: String, CaseIterable, Sendable {
    case happy      // big smile + raised brows
    case neutral    // gentle closed-mouth look
    case sleepy     // half-lidded eyes, tiny mouth
    case sparkle    // star-struck excited eyes

    /// Spoken by VoiceOver.
    public var description: String {
        switch self {
        case .happy: return "happy"
        case .neutral: return "calm"
        case .sleepy: return "sleepy"
        case .sparkle: return "excited"
        }
    }
}

/// The NutriQuest chibi mascot, ported 1:1 from the design system SVG and
/// parameterized: character color, chest stat badge, and expression.
///
/// The mascot's colors come from the character's own color, so the same
/// geometry renders every character in the collection.
public struct ChibiCharacterView: View {
    private let color: NQCharacterColor
    private let statType: NQStatType
    private let expression: ChibiExpression

    public init(color: NQCharacterColor, statType: NQStatType, expression: ChibiExpression = .happy) {
        self.color = color
        self.statType = statType
        self.expression = expression
    }

    public var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 100, geo.size.height / 130)
            ZStack {
                Canvas { context, size in
                    var c = context
                    c.translateBy(
                        x: (size.width - 100 * scale) / 2,
                        y: (size.height - 130 * scale) / 2
                    )
                    c.scaleBy(x: scale, y: scale)
                    draw(&c)
                }
            }
        }
        .aspectRatio(100.0 / 130.0, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(color.name), \(statType.displayName) character, \(expression.description)")
    }

    // MARK: Geometry (design space 100 x 130)

    private func draw(_ context: inout GraphicsContext) {
        let accent = color.accent
        let dark = color.accentDark
        let soft = color.accentSoft
        let ink = NQTheme.inkDeep

        // Ground shadow
        ellipse(&context, cx: 50, cy: 128, rx: 38, ry: 7, fill: soft)

        // Feet
        ellipse(&context, cx: 38, cy: 122, rx: 10, ry: 6, fill: dark)
        ellipse(&context, cx: 62, cy: 122, rx: 10, ry: 6, fill: dark)

        // Body
        ellipse(&context, cx: 50, cy: 100, rx: 24, ry: 22, fill: accent)

        // Hands
        circle(&context, cx: 18, cy: 92, r: 9, fill: accent)
        circle(&context, cx: 82, cy: 92, r: 9, fill: accent)

        // Chest badge
        roundedRect(&context, x: 41, y: 92, w: 18, h: 18, radius: 6, fill: dark)
        drawStatIcon(&context)

        // Head
        circle(&context, cx: 50, cy: 48, r: 34, fill: accent)

        // Hair tuft
        path(&context, "M49 14 C53 1 61 -1 58 11 C56 18 51 19 49 14 Z", fill: dark)

        // Eyes
        switch expression {
        case .happy, .neutral:
            ellipse(&context, cx: 38, cy: 51, rx: 7.5, ry: 9.5, fill: .white)
            ellipse(&context, cx: 62, cy: 51, rx: 7.5, ry: 9.5, fill: .white)
            circle(&context, cx: 39, cy: 53, r: 5, fill: ink)
            circle(&context, cx: 63, cy: 53, r: 5, fill: ink)
            circle(&context, cx: 37, cy: 50, r: 1.8, fill: .white)
            circle(&context, cx: 61, cy: 50, r: 1.8, fill: .white)
        case .sleepy:
            // Half-lidded: white eye + lid covering top half
            ellipse(&context, cx: 38, cy: 51, rx: 7.5, ry: 9.5, fill: .white)
            ellipse(&context, cx: 62, cy: 51, rx: 7.5, ry: 9.5, fill: .white)
            circle(&context, cx: 39, cy: 54, r: 4.4, fill: ink)
            circle(&context, cx: 63, cy: 54, r: 4.4, fill: ink)
            path(&context, "M30.5 50 Q38 44 45.5 50 L45.5 42 L30.5 42 Z", fill: accent)
            path(&context, "M54.5 50 Q62 44 69.5 50 L69.5 42 L54.5 42 Z", fill: accent)
        case .sparkle:
            // Star pupils
            ellipse(&context, cx: 38, cy: 51, rx: 8, ry: 10, fill: .white)
            ellipse(&context, cx: 62, cy: 51, rx: 8, ry: 10, fill: .white)
            star(&context, center: CGPoint(x: 39, y: 53), outer: 5.5, inner: 2.4, fill: NQTheme.gold)
            star(&context, center: CGPoint(x: 63, y: 53), outer: 5.5, inner: 2.4, fill: NQTheme.gold)
        }

        // Brows
        stroke(&context, "M31 41 Q38 37 45 41", color: ink, width: 2)
        stroke(&context, "M55 41 Q62 37 69 41", color: ink, width: 2)

        // Blush
        ellipse(&context, cx: 28, cy: 62, rx: 6, ry: 3.6, fill: NQTheme.blush.opacity(0.55))
        ellipse(&context, cx: 72, cy: 62, rx: 6, ry: 3.6, fill: NQTheme.blush.opacity(0.55))

        // Mouth
        switch expression {
        case .happy:
            stroke(&context, "M43 64 Q50 70 57 64", color: ink, width: 2.6)
        case .neutral:
            stroke(&context, "M45 66 Q50 68.5 55 66", color: ink, width: 2.4)
        case .sleepy:
            stroke(&context, "M46 66 Q50 68 54 66", color: ink, width: 2.2)
        case .sparkle:
            // Open happy mouth
            ellipse(&context, cx: 50, cy: 66, rx: 5, ry: 4, fill: ink)
            ellipse(&context, cx: 50, cy: 67.6, rx: 3, ry: 1.8, fill: NQTheme.blush)
        }
    }

    // MARK: Stat icon (white, centered in chest badge)

    private func drawStatIcon(_ context: inout GraphicsContext) {
        context.scaleBy(x: 1, y: 1)
        switch statType {
        case .protein:
            // Dumbbell
            rect(&context, x: 43.5, y: 97, w: 2.6, h: 8, radius: 1, fill: .white)
            rect(&context, x: 53.9, y: 97, w: 2.6, h: 8, radius: 1, fill: .white)
            rect(&context, x: 46.5, y: 98.6, w: 7, h: 4.8, radius: 1.6, fill: .white)
        case .fiber:
            // Leaf
            path(&context, "M50 96.5 C55 98 56.5 103 50 105.5 C43.5 103 45 98 50 96.5 Z", fill: .white)
            stroke(&context, "M50 97.5 L50 105", color: color.accentDark, width: 1.1)
        case .vitamin:
            star(&context, center: CGPoint(x: 50, y: 101), outer: 5.2, inner: 2.2, fill: .white)
        case .hydration:
            path(&context, "M50 95.5 C51.2 98.5 47.5 99.5 47.5 102.2 A2.5 2.5 0 0052.5 102.2 C52.5 100.5 51.2 99.8 50 95.5 Z", fill: .white)
        }
    }

    // MARK: Drawing primitives

    private func ellipse(_ c: inout GraphicsContext, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, fill: Color) {
        c.fill(Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)), with: .color(fill))
    }

    private func circle(_ c: inout GraphicsContext, cx: CGFloat, cy: CGFloat, r: CGFloat, fill: Color) {
        c.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)), with: .color(fill))
    }

    private func roundedRect(_ c: inout GraphicsContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, radius: CGFloat, fill: Color) {
        c.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: radius), with: .color(fill))
    }

    private func rect(_ c: inout GraphicsContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, radius: CGFloat, fill: Color) {
        roundedRect(&c, x: x, y: y, w: w, h: h, radius: radius, fill: fill)
    }

    private func path(_ c: inout GraphicsContext, _ d: String, fill: Color) {
        guard let p = SVGPath.parse(d) else { return }
        c.fill(p, with: .color(fill))
    }

    private func stroke(_ c: inout GraphicsContext, _ d: String, color: Color, width: CGFloat) {
        guard let p = SVGPath.parse(d) else { return }
        c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func star(_ c: inout GraphicsContext, center: CGPoint, outer: CGFloat, inner: CGFloat, fill: Color) {
        var p = Path()
        let step = CGFloat.pi * 2 / 10
        for i in 0..<10 {
            let r = i % 2 == 0 ? outer : inner
            let angle = CGFloat(i) * step - .pi / 2
            let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        p.closeSubpath()
        c.fill(p, with: .color(fill))
    }
}

/// Minimal SVG path parser — supports M, L, C, Q, Z with absolute and relative
/// forms, which covers every path used by the chibi mascot.
public enum SVGPath {
    public static func parse(_ d: String) -> Path? {
        var path = Path()
        var x: CGFloat = 0, y: CGFloat = 0
        var startX: CGFloat = 0, startY: CGFloat = 0
        var i = d.startIndex

        func number() -> CGFloat? {
            while i < d.endIndex, d[i] == " " || d[i] == "," { i = d.index(after: i) }
            var str = ""
            if i < d.endIndex, d[i] == "-" { str.append("-"); i = d.index(after: i) }
            while i < d.endIndex, d[i].isNumber || d[i] == "." {
                str.append(d[i]); i = d.index(after: i)
            }
            return str.isEmpty ? nil : CGFloat(Double(str) ?? 0)
        }

        func point() -> CGPoint? {
            guard let nx = number(), let ny = number() else { return nil }
            return CGPoint(x: nx, y: ny)
        }

        while i < d.endIndex {
            let ch = d[i]
            i = d.index(after: i)
            switch ch {
            case "M":
                guard let p = point() else { return nil }
                x = p.x; y = p.y; startX = x; startY = y
                path.move(to: CGPoint(x: x, y: y))
            case "m":
                guard let p = point() else { return nil }
                x += p.x; y += p.y; startX = x; startY = y
                path.move(to: CGPoint(x: x, y: y))
            case "L":
                while let p = point() { x = p.x; y = p.y; path.addLine(to: CGPoint(x: x, y: y)) }
            case "l":
                while let p = point() { x += p.x; y += p.y; path.addLine(to: CGPoint(x: x, y: y)) }
            case "C":
                while let c1 = point(), let c2 = point(), let p = point() {
                    path.addCurve(to: CGPoint(x: p.x, y: p.y), control1: c1, control2: c2)
                    x = p.x; y = p.y
                }
            case "c":
                while let c1 = point(), let c2 = point(), let p = point() {
                    path.addCurve(
                        to: CGPoint(x: x + p.x, y: y + p.y),
                        control1: CGPoint(x: x + c1.x, y: y + c1.y),
                        control2: CGPoint(x: x + c2.x, y: y + c2.y)
                    )
                    x += p.x; y += p.y
                }
            case "Q":
                while let c1 = point(), let p = point() {
                    path.addQuadCurve(to: CGPoint(x: p.x, y: p.y), control: c1)
                    x = p.x; y = p.y
                }
            case "q":
                while let c1 = point(), let p = point() {
                    path.addQuadCurve(
                        to: CGPoint(x: x + p.x, y: y + p.y),
                        control: CGPoint(x: x + c1.x, y: y + c1.y)
                    )
                    x += p.x; y += p.y
                }
            case "Z", "z":
                path.closeSubpath()
                x = startX; y = startY
            case " ":
                continue
            default:
                return path
            }
        }
        return path
    }
}
