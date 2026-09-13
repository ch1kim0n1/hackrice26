import SwiftUI

/// Facial expression for the chibi mascot.
public enum ChibiExpression: String, CaseIterable, Sendable {
    case happy      // big smile + raised brows
    case neutral    // gentle closed-mouth look
    case sleepy     // half-lidded eyes, tiny mouth
    case sparkle    // star-struck excited eyes
    case hungry     // pleading eyes + small frown — nothing scanned yet today
    case proud      // closed ^^ eyes + open grin — strong day
    case hurt       // squeezed eyes + wavy mouth — lost the last battle

    /// Spoken by VoiceOver.
    public var description: String {
        switch self {
        case .happy: return "happy"
        case .neutral: return "calm"
        case .sleepy: return "sleepy"
        case .sparkle: return "excited"
        case .hungry: return "hungry"
        case .proud: return "proud"
        case .hurt: return "hurt"
        }
    }
}

/// Body silhouette variants — every character gets a distinct shape derived
/// deterministically from its name, so a collection reads as a cast of
/// individuals rather than one mascot recolored.
public enum ChibiPose: String, CaseIterable, Sendable {
    case standard   // balanced
    case tall       // tall + narrow, small head
    case round      // wide + squat, big head
    case wiry       // narrow, long limbs, wide stance
    case broad      // big body, wide shoulders

    /// Deterministic pose from a name so the same character always matches.
    public static func forName(_ name: String) -> ChibiPose {
        return ChibiPose.allCases[nameHash(name) % ChibiPose.allCases.count]
    }

    /// Pose for a character summoned from a photographed dish.
    ///
    /// The food group picks the build — leafy plates read light and wiry, a
    /// protein plate reads broad and sturdy — so a salad and a steak are
    /// distinguishable by silhouette alone. Within a group the name still
    /// varies the choice, so two salads aren't identical twins.
    ///
    /// A nil group (barcode scans, the hand-drawn starter roster) keeps the
    /// original name-hash behaviour untouched.
    public static func forFoodGroup(_ group: String?, name: String) -> ChibiPose {
        let candidates: [ChibiPose]
        switch group {
        case "produce": candidates = [.wiry, .tall]
        case "grain":   candidates = [.round, .standard]
        case "dairy":   candidates = [.round, .broad]
        case "protein": candidates = [.broad, .standard]
        default:        return forName(name)
        }
        return candidates[nameHash(name) % candidates.count]
    }

    static func nameHash(_ name: String) -> Int {
        abs(name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
    }

    var headRadius: CGFloat { switch self { case .standard: 34; case .tall: 30; case .round: 38; case .wiry: 31; case .broad: 33 } }
    var headCy: CGFloat { switch self { case .standard: 48; case .tall: 44; case .round: 46; case .wiry: 45; case .broad: 47 } }
    var bodyRx: CGFloat { switch self { case .standard: 24; case .tall: 20; case .round: 30; case .wiry: 19; case .broad: 29 } }
    var bodyRy: CGFloat { switch self { case .standard: 22; case .tall: 26; case .round: 20; case .wiry: 24; case .broad: 24 } }
    var bodyCy: CGFloat { switch self { case .standard: 100; case .tall: 102; case .round: 101; case .wiry: 101; case .broad: 100 } }
    var handCx: CGFloat { switch self { case .standard: 18; case .tall: 21; case .round: 14; case .wiry: 12; case .broad: 10 } }
    var handCy: CGFloat { switch self { case .standard: 92; case .tall: 94; case .round: 92; case .wiry: 90; case .broad: 90 } }
    var handR: CGFloat { switch self { case .standard: 9; case .tall: 8; case .round: 10; case .wiry: 8; case .broad: 11 } }
    var feetDx: CGFloat { switch self { case .standard: 12; case .tall: 10; case .round: 14; case .wiry: 18; case .broad: 16 } }
    var feetRy: CGFloat { switch self { case .standard: 6; case .tall: 5.5; case .round: 6.5; case .wiry: 5; case .broad: 6.5 } }
}

/// Decoration layer that says what kind of food the character came from.
/// Sits on top of the body, under the chest badge, so it reinforces the pose
/// without ever obscuring the stat readout.
public enum ChibiMotif: String, CaseIterable, Sendable {
    case leafy      // produce — sprigs at the shoulders
    case grainy     // grain — scattered seeds
    case creamy     // dairy — soft blobs
    case hearty     // protein — shoulder plates
    case plain      // other / unknown — no decoration

    /// Motif for a dish's food group. Unknown or absent groups stay plain, so
    /// barcode characters look exactly as they did before.
    public static func forFoodGroup(_ group: String?) -> ChibiMotif {
        switch group {
        case "produce": return .leafy
        case "grain":   return .grainy
        case "dairy":   return .creamy
        case "protein": return .hearty
        default:        return .plain
        }
    }
}

/// The NutriQuest chibi mascot, ported 1:1 from the design system SVG and
/// parameterized: character color, chest stat badge, expression, a
/// deterministic body pose, and a food-group motif so characters read as
/// distinct individuals.
public struct ChibiCharacterView: View {
    private let color: NQCharacterColor
    private let statType: NQStatType
    private let expression: ChibiExpression
    private let showFace: Bool
    private let pose: ChibiPose
    private let motif: ChibiMotif
    /// Mystery shadow for locked collection cards — pose still varies, color does not.
    private let silhouette: Bool

    public init(
        color: NQCharacterColor,
        statType: NQStatType,
        expression: ChibiExpression = .happy,
        showFace: Bool = true,
        pose: ChibiPose? = nil,
        motif: ChibiMotif = .plain,
        silhouette: Bool = false
    ) {
        self.color = color
        self.statType = statType
        self.expression = expression
        self.showFace = showFace
        self.pose = pose ?? ChibiPose.forName(color.name)
        self.motif = motif
        self.silhouette = silhouette
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
        let accent = silhouette ? NQTheme.lockedFill : color.accent
        let dark = silhouette ? NQTheme.chrome : color.accentDark
        let soft = silhouette ? NQTheme.track : color.accentSoft
        let ink = NQTheme.inkDeep
        let p = pose

        // Ground shadow
        ellipse(&context, cx: 50, cy: 128, rx: p.bodyRx + 14, ry: 7, fill: soft)

        // Feet
        ellipse(&context, cx: 50 - p.feetDx, cy: 122, rx: 10, ry: p.feetRy, fill: dark, stroke: ink, line: 1.6)
        ellipse(&context, cx: 50 + p.feetDx, cy: 122, rx: 10, ry: p.feetRy, fill: dark, stroke: ink, line: 1.6)

        // Body
        ellipse(&context, cx: 50, cy: p.bodyCy, rx: p.bodyRx, ry: p.bodyRy, fill: accent, stroke: ink, line: 1.8)

        // Hands
        circle(&context, cx: p.handCx, cy: p.handCy, r: p.handR, fill: accent, stroke: ink, line: 1.6)
        circle(&context, cx: 100 - p.handCx, cy: p.handCy, r: p.handR, fill: accent, stroke: ink, line: 1.6)

        if !silhouette {
            // Food-group motif — drawn on the body, clear of the chest badge.
            drawMotif(&context, p: p)

            // Chest badge
            roundedRect(&context, x: 41, y: p.bodyCy - 8, w: 18, h: 18, radius: 6, fill: dark)
            drawStatIcon(&context, badgeCy: p.bodyCy + 1)
        }

        // Head
        circle(&context, cx: 50, cy: p.headCy, r: p.headRadius, fill: accent, stroke: ink, line: 2)

        // Hair tuft — shape varies with pose for extra silhouette distinction
        switch p {
        case .round:
            path(&context, "M46 12 C50 -2 66 0 60 12 C56 20 48 19 46 12 Z", fill: dark)
        case .wiry:
            path(&context, "M48 16 C46 4 52 0 54 10 C55 16 50 18 48 16 Z", fill: dark)
        case .broad:
            path(&context, "M44 14 C50 0 64 2 56 14 C52 20 46 19 44 14 Z", fill: dark)
        default:
            path(&context, "M49 14 C53 1 61 -1 58 11 C56 18 51 19 49 14 Z", fill: dark)
        }

        if !silhouette {
            // Head accessory per stat type — silhouette reads at a glance
            drawHeadAccessory(&context, headCy: p.headCy, headR: p.headRadius)
        }

        guard showFace else { return }

        // Eyes (positions scale with head)
        let eyeDx: CGFloat = p.headRadius * 0.35
        let eyeCy = p.headCy + 3
        switch expression {
        case .happy, .neutral:
            ellipse(&context, cx: 50 - eyeDx, cy: eyeCy, rx: 7.5, ry: 9.5, fill: .white)
            ellipse(&context, cx: 50 + eyeDx, cy: eyeCy, rx: 7.5, ry: 9.5, fill: .white)
            circle(&context, cx: 50 - eyeDx + 1, cy: eyeCy + 2, r: 5, fill: ink)
            circle(&context, cx: 50 + eyeDx + 1, cy: eyeCy + 2, r: 5, fill: ink)
            circle(&context, cx: 50 - eyeDx - 2, cy: eyeCy - 1, r: 1.8, fill: .white)
            circle(&context, cx: 50 + eyeDx - 2, cy: eyeCy - 1, r: 1.8, fill: .white)
        case .sleepy:
            ellipse(&context, cx: 50 - eyeDx, cy: eyeCy, rx: 7.5, ry: 9.5, fill: .white)
            ellipse(&context, cx: 50 + eyeDx, cy: eyeCy, rx: 7.5, ry: 9.5, fill: .white)
            circle(&context, cx: 50 - eyeDx + 1, cy: eyeCy + 3, r: 4.4, fill: ink)
            circle(&context, cx: 50 + eyeDx + 1, cy: eyeCy + 2, r: 4.4, fill: ink)
            path(&context, "M\(42.5 - eyeDx) \(eyeCy - 1) Q\(50 - eyeDx) \(eyeCy - 7) \(57.5 - eyeDx) \(eyeCy - 1) L\(57.5 - eyeDx) \(eyeCy - 9) L\(42.5 - eyeDx) \(eyeCy - 9) Z", fill: accent)
            path(&context, "M\(42.5 + eyeDx) \(eyeCy - 1) Q\(50 + eyeDx) \(eyeCy - 7) \(57.5 + eyeDx) \(eyeCy - 1) L\(57.5 + eyeDx) \(eyeCy - 9) L\(42.5 + eyeDx) \(eyeCy - 9) Z", fill: accent)
        case .sparkle:
            ellipse(&context, cx: 50 - eyeDx, cy: eyeCy, rx: 8, ry: 10, fill: .white)
            ellipse(&context, cx: 50 + eyeDx, cy: eyeCy, rx: 8, ry: 10, fill: .white)
            star(&context, center: CGPoint(x: 50 - eyeDx + 1, y: eyeCy + 2), outer: 5.5, inner: 2.4, fill: NQTheme.gold)
            star(&context, center: CGPoint(x: 50 + eyeDx + 1, y: eyeCy + 2), outer: 5.5, inner: 2.4, fill: NQTheme.gold)
        case .hungry:
            // Big pleading eyes, pupils lifted — begging for a scan.
            ellipse(&context, cx: 50 - eyeDx, cy: eyeCy, rx: 8, ry: 10, fill: .white)
            ellipse(&context, cx: 50 + eyeDx, cy: eyeCy, rx: 8, ry: 10, fill: .white)
            circle(&context, cx: 50 - eyeDx + 1, cy: eyeCy, r: 5, fill: ink)
            circle(&context, cx: 50 + eyeDx + 1, cy: eyeCy, r: 5, fill: ink)
            circle(&context, cx: 50 - eyeDx - 1.5, cy: eyeCy - 2.5, r: 2, fill: .white)
            circle(&context, cx: 50 + eyeDx - 1.5, cy: eyeCy - 2.5, r: 2, fill: .white)
        case .proud:
            // Closed ^^ eyes — contented, chin-up look.
            stroke(&context, "M\(50 - eyeDx - 6) \(eyeCy + 2) Q\(50 - eyeDx) \(eyeCy - 6) \(50 - eyeDx + 6) \(eyeCy + 2)", color: ink, width: 2.6)
            stroke(&context, "M\(50 + eyeDx - 6) \(eyeCy + 2) Q\(50 + eyeDx) \(eyeCy - 6) \(50 + eyeDx + 6) \(eyeCy + 2)", color: ink, width: 2.6)
        case .hurt:
            // Squeezed-shut > < eyes.
            stroke(&context, "M\(50 - eyeDx - 6) \(eyeCy - 4) L\(50 - eyeDx + 5) \(eyeCy + 3)", color: ink, width: 2.4)
            stroke(&context, "M\(50 - eyeDx - 6) \(eyeCy + 3) L\(50 - eyeDx + 5) \(eyeCy - 4)", color: ink, width: 2.4)
            stroke(&context, "M\(50 + eyeDx - 5) \(eyeCy - 4) L\(50 + eyeDx + 6) \(eyeCy + 3)", color: ink, width: 2.4)
            stroke(&context, "M\(50 + eyeDx - 5) \(eyeCy + 3) L\(50 + eyeDx + 6) \(eyeCy - 4)", color: ink, width: 2.4)
        }

        // Brows
        stroke(&context, "M\(50 - eyeDx - 7) \(p.headCy - 7) Q\(50 - eyeDx) \(p.headCy - 11) \(50 - eyeDx + 7) \(p.headCy - 7)", color: ink, width: 2)
        stroke(&context, "M\(50 + eyeDx - 7) \(p.headCy - 7) Q\(50 + eyeDx) \(p.headCy - 7 - 4) \(50 + eyeDx + 7) \(p.headCy - 7)", color: ink, width: 2)

        // Blush
        ellipse(&context, cx: 50 - p.headRadius * 0.65, cy: p.headCy + 14, rx: 6, ry: 3.6, fill: NQTheme.blush.opacity(0.55))
        ellipse(&context, cx: 50 + p.headRadius * 0.65, cy: p.headCy + 14, rx: 6, ry: 3.6, fill: NQTheme.blush.opacity(0.55))

        // Mouth
        let mouthCy = p.headCy + 18
        switch expression {
        case .happy:
            stroke(&context, "M43 \(mouthCy - 2) Q50 \(mouthCy + 4) 57 \(mouthCy - 2)", color: ink, width: 2.6)
        case .neutral:
            stroke(&context, "M45 \(mouthCy) Q50 \(mouthCy + 2.5) 55 \(mouthCy)", color: ink, width: 2.4)
        case .sleepy:
            stroke(&context, "M46 \(mouthCy) Q50 \(mouthCy + 2) 54 \(mouthCy)", color: ink, width: 2.2)
        case .sparkle:
            ellipse(&context, cx: 50, cy: mouthCy, rx: 5, ry: 4, fill: ink)
            ellipse(&context, cx: 50, cy: mouthCy + 1.6, rx: 3, ry: 1.8, fill: NQTheme.blush)
        case .hungry:
            // Small frown — the arc flips down instead of up.
            stroke(&context, "M45 \(mouthCy + 1) Q50 \(mouthCy - 3) 55 \(mouthCy + 1)", color: ink, width: 2.4)
        case .proud:
            // Open grin with tongue hint.
            ellipse(&context, cx: 50, cy: mouthCy - 1, rx: 6, ry: 4.5, fill: ink)
            ellipse(&context, cx: 50, cy: mouthCy + 0.8, rx: 3.4, ry: 2, fill: NQTheme.blush)
        case .hurt:
            // Uneasy wavy line.
            stroke(&context, "M44 \(mouthCy) Q47 \(mouthCy - 2.5) 50 \(mouthCy) Q53 \(mouthCy + 2.5) 56 \(mouthCy)", color: ink, width: 2.2)
        }
    }

    /// Decoration that signals the dish's food group.
    ///
    /// The chest badge occupies x 41...59 around `bodyCy`, so every motif is
    /// placed outside that band — the stat readout always stays legible.
    private func drawMotif(_ c: inout GraphicsContext, p: ChibiPose) {
        let dark = color.accentDark
        let soft = color.accentSoft
        let sideX = p.bodyRx * 0.62

        switch motif {
        case .leafy:
            // Sprigs poking out at both shoulders.
            let shoulderY = p.bodyCy - p.bodyRy * 0.55
            ellipse(&c, cx: 50 - p.bodyRx - 1, cy: shoulderY, rx: 8, ry: 4, fill: dark)
            ellipse(&c, cx: 50 + p.bodyRx + 1, cy: shoulderY, rx: 8, ry: 4, fill: dark)
            ellipse(&c, cx: 50 - p.bodyRx - 1, cy: shoulderY, rx: 4, ry: 2, fill: soft)
            ellipse(&c, cx: 50 + p.bodyRx + 1, cy: shoulderY, rx: 4, ry: 2, fill: soft)

        case .grainy:
            // Scattered seeds either side of the badge.
            for dx in [-sideX, sideX] {
                ellipse(&c, cx: 50 + dx, cy: p.bodyCy - 2, rx: 2.4, ry: 3.4, fill: soft)
                ellipse(&c, cx: 50 + dx * 0.72, cy: p.bodyCy + p.bodyRy * 0.5, rx: 2.4, ry: 3.4, fill: soft)
            }

        case .creamy:
            // Soft cream blobs flanking the badge.
            ellipse(&c, cx: 50 - sideX, cy: p.bodyCy + 1, rx: 6, ry: 4.5, fill: soft)
            ellipse(&c, cx: 50 + sideX, cy: p.bodyCy + 1, rx: 6, ry: 4.5, fill: soft)

        case .hearty:
            // Armour-ish shoulder plates: sturdy silhouette for a protein plate.
            let plateY = p.bodyCy - p.bodyRy * 0.72
            roundedRect(&c, x: 50 - p.bodyRx - 2, y: plateY, w: 14, h: 7, radius: 3.5, fill: dark)
            roundedRect(&c, x: 50 + p.bodyRx - 12, y: plateY, w: 14, h: 7, radius: 3.5, fill: dark)

        case .plain:
            break
        }
    }

    /// Small crown accessory that changes the head silhouette per stat type.
    private func drawHeadAccessory(_ c: inout GraphicsContext, headCy: CGFloat, headR: CGFloat) {
        let top = headCy - headR
        switch statType {
        case .fiber:
            // Leaf sprout
            path(&c, "M50 \(top + 2) C54 \(top - 6) 60 \(top - 6) 58 \(top + 1) C56 \(top + 4) 52 \(top + 4) 50 \(top + 2) Z", fill: color.accentDark)
        case .protein:
            // Bolt antenna
            stroke(&c, "M50 \(top + 3) L50 \(top - 5)", color: color.accentDark, width: 2.2)
            path(&c, "M50 \(top - 10) L54 \(top - 5) L50 \(top - 4) L50 \(top - 10) Z", fill: NQTheme.gold)
        case .vitamin:
            star(&c, center: CGPoint(x: 50, y: top - 2), outer: 5, inner: 2.1, fill: NQTheme.gold)
        case .hydration:
            path(&c, "M50 \(top - 8) C52 \(top - 4) 47 \(top - 3) 47 \(top) A3 3 0 0053 \(top) C53 \(top - 2) 51.5 \(top - 5) 50 \(top - 8) Z", fill: color.accentDark)
        }
    }

    // MARK: Stat icon (white, centered in chest badge)

    private func drawStatIcon(_ context: inout GraphicsContext, badgeCy: CGFloat) {
        let dy = badgeCy - 101
        context.translateBy(x: 0, y: dy)
        defer { context.translateBy(x: 0, y: -dy) }
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

    private func ellipse(_ c: inout GraphicsContext, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, fill: Color, stroke: Color? = nil, line: CGFloat = 1.8) {
        let rect = CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
        c.fill(Path(ellipseIn: rect), with: .color(fill))
        if let stroke {
            c.stroke(Path(ellipseIn: rect), with: .color(stroke), lineWidth: line)
        }
    }

    private func circle(_ c: inout GraphicsContext, cx: CGFloat, cy: CGFloat, r: CGFloat, fill: Color, stroke: Color? = nil, line: CGFloat = 1.8) {
        ellipse(&c, cx: cx, cy: cy, rx: r, ry: r, fill: fill, stroke: stroke, line: line)
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
