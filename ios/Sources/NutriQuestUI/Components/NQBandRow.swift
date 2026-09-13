import SwiftUI

/// A colored dot + label + range row, for rarity brackets and price bands.
public struct NQBandRow: View {
    private let color: Color
    private let label: String
    private let range: String

    public init(color: Color, label: String, range: String) {
        self.color = color
        self.label = label
        self.range = range
    }

    public var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(NQText.heading.font)
                .foregroundStyle(NQTheme.ink)
            Spacer()
            Text(range)
                .font(NQText.caption.font.weight(.bold))
                .foregroundStyle(NQTheme.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }
}
