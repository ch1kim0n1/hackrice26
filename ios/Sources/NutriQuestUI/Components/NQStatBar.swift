import SwiftUI

/// An inset, segmented RPG meter. Values and accessibility stay unchanged.
public struct NQStatBar: View {
    public static let barHeight: CGFloat = 12

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
                    RoundedRectangle(cornerRadius: 3)
                        .fill(trackTint ?? NQTheme.track)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(
                            colors: [(fillTint ?? accent.accent).tinted(0.25), fillTint ?? accent.accent],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(width: max(0, geo.size.width * value))
                    HStack(spacing: 0) {
                        ForEach(0..<10) { _ in
                            Spacer(minLength: 0)
                            Rectangle().fill(NQTheme.inkDeep.opacity(0.35)).frame(width: 1)
                        }
                    }
                    .allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(NQTheme.inkDeep, lineWidth: 1.5)
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

/// Dialogue-style notice panel with a colored status diamond.
public struct NQBanner: View {
    private let message: Text
    private var dotColor: Color?
    private var onDismiss: (() -> Void)?

    @Environment(\.nqAccent) private var accent

    public init(_ message: Text, dotColor: Color? = nil, onDismiss: (() -> Void)? = nil) {
        self.message = message
        self.dotColor = dotColor
        self.onDismiss = onDismiss
    }

    public init(_ message: String, dotColor: Color? = nil, onDismiss: (() -> Void)? = nil) {
        // Callers pass markdown (**bold**); render it instead of showing
        // literal asterisks. Falls back to plain text on malformed markdown.
        // .inlineOnlyPreservingWhitespace avoids block-level reinterpretation
        // and whitespace collapsing, which matter for a single-line banner.
        let parsed = try? AttributedString(
            markdown: message,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        self.message = Text(parsed ?? AttributedString(message))
        self.dotColor = dotColor
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: NQTheme.spaceS + 2) {
            Rectangle()
                .frame(width: 7, height: 7)
                .rotationEffect(.degrees(45))
                .foregroundStyle(dotColor ?? accent.accent)
                .accessibilityHidden(true)
            message
                .font(NQText.body.font)
                .foregroundStyle(NQTheme.inkSubtle)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: NQLayout.iconXS, weight: .bold))
                        .foregroundStyle(NQTheme.inkFaint)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .nqPadding(.banner)
        .nqSurface(.banner)
        .overlay { NQPanelShape().strokeBorder((dotColor ?? accent.accent).opacity(0.5), lineWidth: 1) }
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
        HStack(alignment: .firstTextBaseline, spacing: NQTheme.spaceS) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(NQTheme.gold)
                .accessibilityHidden(true)
            Text(title)
                .font(NQText.headingL.font)
                .foregroundStyle(NQTheme.ink)
                .shadow(color: NQTheme.inkDeep, radius: 0, y: 2)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(NQText.caption.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
        }
    }
}
