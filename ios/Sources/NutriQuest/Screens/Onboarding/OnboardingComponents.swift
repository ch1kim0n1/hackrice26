import SwiftUI
import NutriQuestUI

// MARK: - Theme

/// Design tokens for the hackrice onboarding flow.
/// Thin aliases over NQTheme so onboarding shares the home screen's
/// visual language: warm coral-washed page, white sticker cards with
/// ink strokes, and the single coral accent.
enum OBTheme {
    /// Primary text color — headlines and card titles.
    static let ink = NQTheme.ink
    /// Secondary copy under headlines.
    static let subtitle = NQTheme.inkMuted
    /// Card fill for unselected option cards and chips (pure white,
    /// paired with an ink stroke and sticker shadow like home cards).
    static let optionFill = NQTheme.background
    /// Progress-bar track and ruler baseline grey.
    static let track = NQTheme.track
    /// Disabled primary button fill.
    static let disabledFill = NQTheme.lockedFill
    /// The app accent — coral, same as home's buttons and rings.
    static let accent = NQTheme.accent
    /// Darker accent for pressed/emphasis states.
    static let accentDark = NQTheme.accentDark
    /// Warm page wash behind the cards, identical to the home screen.
    static let page = NQTheme.accentBg
    /// Horizontal screen inset shared by every step (home's screen padding).
    static let screenInset: CGFloat = 20
}

// MARK: - Wordmark

/// NutriQuest lockup: mark plus wordmark, same as the in-game top bar.
struct OBWordmark: View {
    var size: CGFloat = 40

    var body: some View {
        HStack(spacing: size * 0.25) {
            NQLogoMark()
                .frame(width: size * 0.85, height: size * 0.85)
            Text("NutriQuest")
                .font(NQFont.display.font(size))
                .foregroundStyle(NQTheme.gold)
                .shadow(color: NQTheme.inkDeep, radius: 0, y: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("NutriQuest")
    }
}

// MARK: - Progress header

/// Circular back button plus thin progress bar, shown on every step
/// after the welcome screen.
struct OBProgressHeader: View {
    /// Progress through the flow, 0...1.
    let progress: Double
    /// Back action; pass nil to hide the button while keeping layout.
    var onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 18) {
            Button {
                onBack?()
            } label: {
                ZStack {
                    Circle()
                        .fill(NQTheme.background)
                        .frame(width: 44, height: 44)
                        .nqInkStroke(Circle(), lineWidth: 1.5)
                        .nqElevation(.sticker)
                    Image(systemName: "arrow.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(OBTheme.ink)
                }
            }
            .opacity(onBack == nil ? 0 : 1)
            .disabled(onBack == nil)
            .accessibilityLabel("Back")

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(OBTheme.track).frame(height: 5)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [OBTheme.accent, OBTheme.accentDark],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(14, geo.size.width * progress), height: 5)
                        .animation(.easeOut(duration: 0.3), value: progress)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 44)
        }
    }
}

// MARK: - Primary button

/// Full-width coral pill button used as the primary action on every step,
/// matching the home screen's primary-action styling (accent fill with a
/// soft ink stroke).
struct OBPrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            Text(title)
                .font(NQFont.heading.font(17))
                .foregroundStyle(enabled ? OBTheme.accent.readableTextColor() : NQTheme.inkMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .nqPlate(NQPanelShape(), fill: enabled ? OBTheme.accent : OBTheme.disabledFill, inkStroke: true)
        }
        .animation(.easeOut(duration: 0.2), value: enabled)
    }
}

// MARK: - Option card

/// Selectable answer row: white sticker card (ink stroke + hard shadow,
/// like home's cards) that fills with the coral accent when selected.
/// Supports an optional leading icon and subtitle.
struct OBOptionCard: View {
    let title: String
    var subtitle: String?
    var icon: AnyView?
    /// Centers the title when there is no icon/subtitle (gender screen).
    var centered: Bool = false
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if let icon {
                    ZStack {
                        Circle()
                            .fill(selected ? NQTheme.chrome : NQTheme.surface)
                            .frame(width: 44, height: 44)
                        icon
                    }
                }
                VStack(alignment: centered ? .center : .leading, spacing: 2) {
                    Text(title)
                        .font(NQFont.heading.font(16))
                        .foregroundStyle(selected ? OBTheme.accent.readableTextColor() : OBTheme.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(NQFont.body.font(13))
                            .foregroundStyle(selected ? OBTheme.accent.readableTextColor().opacity(0.8) : OBTheme.subtitle)
                    }
                }
                .frame(maxWidth: centered ? .infinity : nil, alignment: centered ? .center : .leading)
                if !centered { Spacer(minLength: 0) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, subtitle == nil ? 19 : 14)
            .frame(maxWidth: .infinity)
            .nqPlate(
                RoundedRectangle(cornerRadius: NQTheme.radiusM),
                fill: selected ? OBTheme.accent : OBTheme.optionFill,
                elevation: .sticker,
                inkStroke: true
            )
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: selected)
    }
}

// MARK: - Step scaffold

/// Shared layout for a questionnaire step: left-aligned title and
/// subtitle up top, flexible content, and a pinned primary button.
struct OBStepScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    var buttonTitle: String = "Continue"
    var buttonEnabled: Bool = true
    /// Optional plain-text secondary action under the primary button.
    var secondaryTitle: String?
    var onSecondary: (() -> Void)?
    let onContinue: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(NQFont.display.font(28))
                .foregroundStyle(OBTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            if let subtitle {
                Text(subtitle)
                    .font(NQFont.body.font(15))
                    .foregroundStyle(OBTheme.subtitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            Spacer(minLength: 12)
            content
            Spacer(minLength: 12)

            OBPrimaryButton(title: buttonTitle, enabled: buttonEnabled, action: onContinue)
            if let secondaryTitle {
                Button {
                    onSecondary?()
                } label: {
                    Text(secondaryTitle)
                        .font(NQFont.heading.font(16))
                        .foregroundStyle(OBTheme.accentDark)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Ruler slider

/// Horizontal ruler-style weight picker: drag to scrub the value, ticks
/// scroll underneath a fixed center cursor. Mirrors the Figma desired
/// weight screen.
struct OBRulerSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 30...200

    /// Points of horizontal travel per whole unit (kg or lb).
    private let unitSpacing: CGFloat = 9
    @State private var dragBase: Double?

    var body: some View {
        GeometryReader { geo in
            let mid = geo.size.width / 2
            ZStack(alignment: .top) {
                // Shaded region to the right of the cursor, as in the design.
                Rectangle()
                    .fill(OBTheme.track.opacity(0.6))
                    .frame(width: max(0, geo.size.width - mid), height: 58)
                    .offset(x: mid)

                Canvas { context, size in
                    drawTicks(context: context, size: size, center: mid)
                }

                // Fixed center cursor — coral, like home's gauge fill.
                Rectangle()
                    .fill(OBTheme.accent)
                    .frame(width: 2.5, height: 66)
                    .position(x: mid, y: 33)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { g in
                        let base = dragBase ?? value
                        dragBase = base
                        let delta = -Double(g.translation.width / unitSpacing)
                        let raw = min(max(base + delta, range.lowerBound), range.upperBound)
                        value = (raw * 10).rounded() / 10
                    }
                    .onEnded { _ in dragBase = nil }
            )
        }
        .frame(height: 72)
        .accessibilityElement()
        .accessibilityLabel("Desired weight")
        .accessibilityValue(String(format: "%.1f", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 1, range.upperBound)
            case .decrement: value = max(value - 1, range.lowerBound)
            @unknown default: break
            }
        }
    }

    /// Draws the ruler tick marks into the canvas, scrolled so the
    /// current value sits under the fixed center cursor.
    private func drawTicks(context: GraphicsContext, size: CGSize, center: CGFloat) {
        let visibleUnits = Int(size.width / unitSpacing) + 2
        let first = Int(value) - visibleUnits / 2
        let last = Int(value) + visibleUnits / 2
        for unit in first...last {
            guard Double(unit) >= range.lowerBound, Double(unit) <= range.upperBound else { continue }
            let x = center + (CGFloat(Double(unit) - value)) * unitSpacing
            guard x >= -2, x <= size.width + 2 else { continue }
            let major = unit % 5 == 0
            let height: CGFloat = major ? 46 : 24
            var path = Path()
            path.move(to: CGPoint(x: x, y: 4))
            path.addLine(to: CGPoint(x: x, y: 4 + height))
            context.stroke(
                path,
                with: .color(major ? OBTheme.ink.opacity(0.85) : OBTheme.ink.opacity(0.35)),
                lineWidth: major ? 1.6 : 1
            )
        }
    }
}

// MARK: - Phone mockup

/// Stylized phone running the food scanner, used as the welcome hero.
/// Recreates the Figma hero (dark camera view, viewfinder brackets,
/// scan toolbar, shutter) in pure SwiftUI.
struct OBPhoneMockup: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 38)
                .fill(Color(hex: 0x101114))
            RoundedRectangle(cornerRadius: 30)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x3A4454), Color(hex: 0x191C22), Color(hex: 0x0C0D10)],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                )
                .padding(9)
                .overlay { screenContent.padding(9) }
            // Dynamic-island notch.
            Capsule()
                .fill(Color(hex: 0x0A0A0C))
                .frame(width: 74, height: 20)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 18)
        }
        .aspectRatio(0.49, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// Camera UI drawn over the dark screen gradient.
    private var screenContent: some View {
        VStack {
            Spacer()
            Image(systemName: "viewfinder")
                .font(.system(size: 128, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            HStack(spacing: 7) {
                Text("Scan Food")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(OBTheme.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(NQTicketShape().fill(NQTheme.background))
                Image(systemName: "barcode.viewfinder")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                Image(systemName: "photo")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(NQTicketShape().fill(.white.opacity(0.16)))
            HStack {
                ZStack {
                    Circle().fill(.white.opacity(0.16)).frame(width: 28, height: 28)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                }
                Spacer()
                Circle()
                    .fill(.white)
                    .frame(width: 46, height: 46)
                    .overlay(Circle().stroke(Color(hex: 0x101114), lineWidth: 3).padding(3))
                Spacer()
                Color.clear.frame(width: 28, height: 28)
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 18)
        }
    }
}
