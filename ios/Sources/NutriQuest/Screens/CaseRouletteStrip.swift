import SwiftUI
import NutriQuestUI

/// A CS:GO-style case reel: the server's strip of candidates scrolls under a
/// fixed center marker and decelerates onto the winner it already chose.
/// Purely a reveal — it never re-rolls anything.
struct CaseRouletteStrip: View {
    let reel: [LootCharacterDTO]
    let winnerIndex: Int
    let onFinished: () -> Void

    @State private var offsetX: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let tileWidth: CGFloat = 72
    private let tileSpacing: CGFloat = 10
    private let stripHeight: CGFloat = 108
    /// Long enough for the strip to blur past, then crawl onto the winner.
    private let spinDuration: Double = 6

    private var pitch: CGFloat { tileWidth + tileSpacing }

    var body: some View {
        GeometryReader { geo in
            let containerWidth = geo.size.width
            ZStack {
                HStack(spacing: tileSpacing) {
                    ForEach(Array(reel.enumerated()), id: \.offset) { _, character in
                        tile(character)
                    }
                }
                .padding(.horizontal, containerWidth / 2 - tileWidth / 2)
                .offset(x: offsetX ?? 0)
                .frame(width: containerWidth, alignment: .leading)

                // Fixed center marker — the strip moves under it.
                VStack(spacing: 0) {
                    Triangle()
                        .fill(NQTheme.gold)
                        .frame(width: 14, height: 8)
                    Spacer()
                    Triangle()
                        .fill(NQTheme.gold)
                        .frame(width: 14, height: 8)
                        .rotationEffect(.degrees(180))
                }
                .frame(height: stripHeight)
                .allowsHitTesting(false)

                Rectangle()
                    .fill(NQTheme.gold.opacity(0.9))
                    .frame(width: 3)
                    .allowsHitTesting(false)
            }
            .frame(width: containerWidth, height: stripHeight)
            .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
            .overlay {
                RoundedRectangle(cornerRadius: NQTheme.radiusL)
                    .strokeBorder(NQTheme.hairline, lineWidth: NQLayout.hairlineWidth)
            }
            .onAppear { spin() }
        }
        .frame(height: stripHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spinning the case")
    }

    private func spin() {
        let target = -(CGFloat(winnerIndex) * pitch)
        if reduceMotion {
            // Land instantly — the suspense is exactly what Reduce Motion asks to skip.
            offsetX = target
            onFinished()
            return
        }
        offsetX = 0
        withAnimation(.timingCurve(0.1, 0.85, 0.2, 1, duration: spinDuration)) {
            offsetX = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + spinDuration) {
            onFinished()
        }
    }

    private func tile(_ character: LootCharacterDTO) -> some View {
        let rarity = Rarity(rawValue: character.rarity) ?? .common
        return CharacterArtwork(
            character: Character(
                id: character.id,
                name: character.name,
                colorHex: character.colorHex,
                rarity: rarity,
                statType: StatType(rawValue: character.statType) ?? .fiber
            )
        )
        .padding(6)
        .frame(width: tileWidth, height: tileWidth)
        .background(NQTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusM))
        .overlay {
            RoundedRectangle(cornerRadius: NQTheme.radiusM)
                .strokeBorder(rarity.kitRarity.outline.opacity(0.7), lineWidth: 1.5)
        }
    }
}

/// The small pointer on the roulette's center marker.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
    }
}
