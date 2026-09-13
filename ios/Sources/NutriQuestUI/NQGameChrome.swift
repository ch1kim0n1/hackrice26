import SwiftUI

/// Static map-like atmosphere. No assets or perpetual animation required.
public struct NQAdventureBackdrop: View {
    public init() {}

    public var body: some View {
        ZStack {
            LinearGradient(colors: [NQTheme.sky, NQTheme.page, NQTheme.page],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { geo in
                // Soft cloud puffs and little comic sparkles, kept behind content.
                Path { path in
                    path.addEllipse(in: CGRect(x: geo.size.width - 170, y: 30, width: 130, height: 110))
                    path.addEllipse(in: CGRect(x: geo.size.width - 95, y: 0, width: 160, height: 155))
                    path.addEllipse(in: CGRect(x: geo.size.width - 25, y: 70, width: 100, height: 85))
                }
                .fill(NQTheme.ink.opacity(0.045))
                Canvas { context, size in
                    for row in 0..<Int(size.height / 64 + 1) {
                        for column in 0..<Int(size.width / 64 + 1) {
                            let x = CGFloat(column) * 64 + (row.isMultiple(of: 2) ? 16 : 40)
                            let y = CGFloat(row) * 64 + 24
                            if (row + column).isMultiple(of: 4) {
                                let sparkle = Path { p in
                                    p.move(to: CGPoint(x: x, y: y - 4))
                                    p.addQuadCurve(to: CGPoint(x: x + 4, y: y), control: CGPoint(x: x + 1, y: y - 1))
                                    p.addQuadCurve(to: CGPoint(x: x, y: y + 4), control: CGPoint(x: x + 1, y: y + 1))
                                    p.addQuadCurve(to: CGPoint(x: x - 4, y: y), control: CGPoint(x: x - 1, y: y + 1))
                                    p.addQuadCurve(to: CGPoint(x: x, y: y - 4), control: CGPoint(x: x - 1, y: y - 1))
                                }
                                context.fill(sparkle, with: .color(NQTheme.gold.opacity(0.14)))
                            } else {
                                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 3, height: 3)),
                                             with: .color(NQTheme.ink.opacity(0.07)))
                            }
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Small glossy highlights for the cartoon sticker surfaces.
struct NQPanelCorners: View {
    var tint: Color = NQTheme.gold

    var body: some View {
        VStack {
            HStack {
                Capsule().fill(NQTheme.ink.opacity(0.55)).frame(width: 14, height: 3)
                    .rotationEffect(.degrees(-25))
                Spacer()
                Circle().fill(tint.opacity(0.5)).frame(width: 4, height: 4)
            }
            Spacer(minLength: 0)
        }
        .padding(NQTheme.spaceM)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

}

/// Reusable elemental crest for controls and creature placeholders.
public struct NQElementMedallion: View {
    private let icon: NQIcon
    private let tint: Color

    public init(icon: NQIcon, tint: Color = NQTheme.gold) {
        self.icon = icon
        self.tint = tint
    }

    public var body: some View {
        ZStack {
            NQPanelShape(cut: NQTheme.radiusM)
                .fill(LinearGradient(colors: [tint.opacity(0.3), NQTheme.background],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            NQPanelShape(cut: NQTheme.radiusM)
                .strokeBorder(tint.opacity(0.7), lineWidth: 3)
            NQIconView(icon: icon, tint: tint)
                .padding(NQTheme.spaceM)
        }
        .accessibilityHidden(true)
    }
}


/// A cheerful plate placeholder for homemade meals; replaceable with artwork.
public struct NQMealMascot: View {
    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(NQTheme.ink)
                    .shadow(color: NQTheme.inkDeep, radius: 0, y: 4)
                Circle().strokeBorder(NQTheme.inkDeep, lineWidth: 3)
                Circle().strokeBorder(NQTheme.carbs.opacity(0.5), lineWidth: 3).padding(size * 0.1)
                HStack(spacing: -size * 0.05) {
                    Circle().fill(NQTheme.leaf)
                    Circle().fill(NQTheme.carbs).offset(y: -size * 0.08)
                    Circle().fill(NQTheme.protein)
                }
                .frame(width: size * 0.58, height: size * 0.26)
                .offset(y: -size * 0.18)
                HStack(spacing: size * 0.17) {
                    Ellipse().fill(NQTheme.inkDeep)
                    Ellipse().fill(NQTheme.inkDeep)
                }
                .frame(width: size * 0.3, height: size * 0.1)
                .offset(y: size * 0.1)
                Path { p in
                    p.move(to: CGPoint(x: size * 0.4, y: size * 0.68))
                    p.addQuadCurve(to: CGPoint(x: size * 0.6, y: size * 0.68),
                                   control: CGPoint(x: size * 0.5, y: size * 0.83))
                }
                .stroke(NQTheme.inkDeep, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(-8))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
