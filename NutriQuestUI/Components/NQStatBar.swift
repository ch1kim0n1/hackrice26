import SwiftUI

/// Progress / stat bar — soft rounded track, accent fill, optional label row.
public struct NQStatBar: View {
    public static let barHeight: CGFloat = 10

    private let label: String?
    private let value: Double        // 0...1
    private let valueText: String?
    private var trackTint: Color?
    private var fillTint: Color?

    @Environment(\.nqAccent) private var accent

    public init(label: String? = nil, value: Double, valueText: String? = nil) {
        self.label = label
        self.value = min(max(value, 0), 1)
        self.valueText = valueText
    }

    public func track(_ color: Color?) -> NQStatBar {
        var copy = self
        copy.trackTint = color
        return copy
    }

    public func fill(_ color: Color?) -> NQStatBar {
        var copy = self
        copy.fillTint = color
        return copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceXS + 1) {
            if label != nil || valueText != nil {
                HStack {
                    if let label {
                        Text(label)
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                    }
                    Spacer()
                    if let valueText {
                        Text(valueText)
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.ink)
                    }
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(trackTint ?? accent.accentSoft)
                    Capsule()
                        .fill(fillTint ?? accent.accent)
                        .frame(width: max(0, geo.size.width * value))
                }
            }
            .frame(height: Self.barHeight)
            .animation(NQMotion.fill, value: value)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "Progress")
        .accessibilityValue(valueText ?? "\(Int(value * 100)) percent")
    }
}

// MARK: - Status banner

/// White rounded banner with a colored status dot.
public struct NQBanner: View {
    private let message: Text
    private var dotColor: Color?

    @Environment(\.nqAccent) private var accent

    public init(_ message: Text, dotColor: Color? = nil) {
        self.message = message
        self.dotColor = dotColor
    }

    public init(_ message: String, dotColor: Color? = nil) {
        self.message = Text(message)
        self.dotColor = dotColor
    }

    public var body: some View {
        HStack(spacing: NQTheme.spaceM - 4) {
            Circle()
                .frame(width: 9, height: 9)
                .foregroundStyle(dotColor ?? accent.accent)
                .accessibilityHidden(true)
            message
                .font(NQText.body.font)
                .foregroundStyle(NQTheme.inkSubtle)
            Spacer(minLength: 0)
        }
        .nqPadding(.banner)
        .background(NQTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusM))
        .nqElevation(.soft)
    }
}

// MARK: - Section header

public struct NQSectionHeader: View {
    private let title: String
    private let trailing: String?

    public init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(NQText.headingL.font)
                .foregroundStyle(NQTheme.ink)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(NQText.caption.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
        }
    }
}
