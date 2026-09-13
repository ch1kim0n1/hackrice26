import SwiftUI

/// Custom vector icon set — drawn with SwiftUI paths, tintable, no asset
/// catalog needed. Every icon has an optional animated variant.
public enum NQIcon: String, CaseIterable, Sendable {
    case scan, battle, gym, watch, flame, droplet, leaf, star
    case heart, trophy, shield, sparkle, barcode, checkCircle, lock, crown
    case home, grid, person, alert, wifiOff
    case cauldron, chips, portal

    /// Static view.
    public var view: some View {
        NQIconView(icon: self)
    }

    /// Animated variant: pulse (flame/heart), bounce (battle/star), spin (barcode).
    public var animated: some View {
        NQAnimatedIconView(icon: self)
    }

    var path: Path {
        var p = Path()
        switch self {
        case .scan:
            // Viewfinder + barcode lines
            p.addRoundedRect(in: CGRect(x: 2, y: 2, width: 8, height: 8), cornerSize: CGSize(width: 2, height: 2))
            p.addRoundedRect(in: CGRect(x: 14, y: 2, width: 8, height: 8), cornerSize: CGSize(width: 2, height: 2))
            p.addRoundedRect(in: CGRect(x: 2, y: 14, width: 8, height: 8), cornerSize: CGSize(width: 2, height: 2))
            p.addRoundedRect(in: CGRect(x: 14, y: 14, width: 8, height: 8), cornerSize: CGSize(width: 2, height: 2))
            p.addRect(CGRect(x: 8, y: 8, width: 1.6, height: 8))
            p.addRect(CGRect(x: 11.2, y: 8, width: 1.6, height: 8))
            p.addRect(CGRect(x: 14.4, y: 8, width: 1.6, height: 8))
        case .battle:
            // Lightning bolt in shield outline
            p.move(to: CGPoint(x: 12, y: 2))
            p.addLine(to: CGPoint(x: 20, y: 5))
            p.addLine(to: CGPoint(x: 20, y: 11))
            p.addCurve(to: CGPoint(x: 12, y: 22), control1: CGPoint(x: 20, y: 16), control2: CGPoint(x: 16, y: 20))
            p.addCurve(to: CGPoint(x: 4, y: 11), control1: CGPoint(x: 8, y: 20), control2: CGPoint(x: 4, y: 16))
            p.addLine(to: CGPoint(x: 4, y: 5))
            p.closeSubpath()
        case .gym:
            // Dumbbell
            p.addRect(CGRect(x: 1, y: 9, width: 3, height: 6))
            p.addRect(CGRect(x: 4.5, y: 7, width: 3, height: 10))
            p.addRect(CGRect(x: 7.5, y: 10.5, width: 9, height: 3))
            p.addRect(CGRect(x: 16.5, y: 7, width: 3, height: 10))
            p.addRect(CGRect(x: 20, y: 9, width: 3, height: 6))
        case .watch:
            // Watch face + strap
            p.addRoundedRect(in: CGRect(x: 8, y: 0, width: 8, height: 5), cornerSize: CGSize(width: 2, height: 2))
            p.addRoundedRect(in: CGRect(x: 8, y: 19, width: 8, height: 5), cornerSize: CGSize(width: 2, height: 2))
            p.addRoundedRect(in: CGRect(x: 5, y: 5, width: 14, height: 14), cornerSize: CGSize(width: 5, height: 5))
        case .flame:
            // Material design flame
            p.move(to: CGPoint(x: 13.5, y: 0.67))
            p.addCurve(to: CGPoint(x: 14.24, y: 5.47), control1: CGPoint(x: 13.5, y: 0.67), control2: CGPoint(x: 14.24, y: 3.32))
            p.addCurve(to: CGPoint(x: 10.83, y: 9.2), control1: CGPoint(x: 14.24, y: 7.53), control2: CGPoint(x: 12.89, y: 9.2))
            p.addCurve(to: CGPoint(x: 7.2, y: 5.47), control1: CGPoint(x: 10.83, y: 9.2), control2: CGPoint(x: 7.2, y: 7.53))
            p.addCurve(to: CGPoint(x: 7.23, y: 5.11), control1: CGPoint(x: 7.2, y: 5.35), control2: CGPoint(x: 7.23, y: 5.11))
            p.addCurve(to: CGPoint(x: 4, y: 14), control1: CGPoint(x: 5.21, y: 7.51), control2: CGPoint(x: 4, y: 10.62))
            p.addCurve(to: CGPoint(x: 12, y: 22), control1: CGPoint(x: 4, y: 18.42), control2: CGPoint(x: 7.58, y: 22))
            p.addCurve(to: CGPoint(x: 20, y: 14), control1: CGPoint(x: 16.42, y: 22), control2: CGPoint(x: 20, y: 18.42))
            p.addCurve(to: CGPoint(x: 13.5, y: 0.67), control1: CGPoint(x: 20, y: 8.61), control2: CGPoint(x: 17.41, y: 3.8))
            p.closeSubpath()
        case .droplet:
            // Material water drop
            p.move(to: CGPoint(x: 12, y: 2.69))
            p.addLine(to: CGPoint(x: 17.66, y: 8.35))
            p.addCurve(to: CGPoint(x: 17.66, y: 19.66), control1: CGPoint(x: 20.78, y: 11.47), control2: CGPoint(x: 20.78, y: 16.54))
            p.addCurve(to: CGPoint(x: 6.34, y: 19.66), control1: CGPoint(x: 16.1, y: 21.22), control2: CGPoint(x: 7.9, y: 21.22))
            p.addCurve(to: CGPoint(x: 6.34, y: 8.35), control1: CGPoint(x: 3.22, y: 16.54), control2: CGPoint(x: 3.22, y: 11.47))
            p.addLine(to: CGPoint(x: 12, y: 2.69))
            p.closeSubpath()
        case .leaf:
            p.move(to: CGPoint(x: 4, y: 20))
            p.addCurve(to: CGPoint(x: 20, y: 4), control1: CGPoint(x: 4, y: 10), control2: CGPoint(x: 10, y: 4))
            p.addCurve(to: CGPoint(x: 4, y: 20), control1: CGPoint(x: 20, y: 12), control2: CGPoint(x: 12, y: 20))
            p.closeSubpath()
        case .star:
            starPath(&p, center: CGPoint(x: 12, y: 12), outer: 10, inner: 4.2, points: 5)
        case .heart:
            p.move(to: CGPoint(x: 12, y: 21))
            p.addCurve(to: CGPoint(x: 2.5, y: 9), control1: CGPoint(x: 6, y: 17), control2: CGPoint(x: 2.5, y: 13))
            p.addArc(center: CGPoint(x: 7.5, y: 6.5), radius: 5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addArc(center: CGPoint(x: 16.5, y: 6.5), radius: 5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.addCurve(to: CGPoint(x: 12, y: 21), control1: CGPoint(x: 21.5, y: 13), control2: CGPoint(x: 18, y: 17))
            p.closeSubpath()
        case .trophy:
            p.addRect(CGRect(x: 7, y: 3, width: 10, height: 9))
            p.addRect(CGRect(x: 10.5, y: 12, width: 3, height: 5))
            p.addRect(CGRect(x: 7, y: 18, width: 10, height: 3))
            p.addArc(center: CGPoint(x: 5.5, y: 7.5), radius: 3, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
            p.addArc(center: CGPoint(x: 18.5, y: 7.5), radius: 3, startAngle: .degrees(270), endAngle: .degrees(90), clockwise: false)
        case .shield:
            p.move(to: CGPoint(x: 12, y: 2))
            p.addLine(to: CGPoint(x: 20, y: 5))
            p.addLine(to: CGPoint(x: 20, y: 11))
            p.addCurve(to: CGPoint(x: 12, y: 22), control1: CGPoint(x: 20, y: 16), control2: CGPoint(x: 16, y: 20))
            p.addCurve(to: CGPoint(x: 4, y: 11), control1: CGPoint(x: 8, y: 20), control2: CGPoint(x: 4, y: 16))
            p.addLine(to: CGPoint(x: 4, y: 5))
            p.closeSubpath()
        case .sparkle:
            starPath(&p, center: CGPoint(x: 12, y: 12), outer: 10, inner: 3, points: 4)
        case .barcode:
            for (i, w) in [2.0, 1.2, 3.0, 1.2, 2.0, 1.2, 3.0, 1.2, 2.0].enumerated() {
                let x = 3.0 + CGFloat(i) * 2.1
                p.addRect(CGRect(x: x, y: 5, width: CGFloat(w), height: 14))
            }
        case .checkCircle:
            // Bold checkmark (pair with a circled background when needed)
            p.move(to: CGPoint(x: 4, y: 12.5))
            p.addLine(to: CGPoint(x: 9.5, y: 18))
            p.addLine(to: CGPoint(x: 20, y: 6))
            p.closeSubpath()
        case .lock:
            p.addRoundedRect(in: CGRect(x: 5, y: 10, width: 14, height: 11), cornerSize: CGSize(width: 3, height: 3))
            p.addArc(center: CGPoint(x: 12, y: 9), radius: 5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        case .crown:
            p.move(to: CGPoint(x: 3, y: 18))
            p.addLine(to: CGPoint(x: 3, y: 8))
            p.addLine(to: CGPoint(x: 8, y: 12))
            p.addLine(to: CGPoint(x: 12, y: 5))
            p.addLine(to: CGPoint(x: 16, y: 12))
            p.addLine(to: CGPoint(x: 21, y: 8))
            p.addLine(to: CGPoint(x: 21, y: 18))
            p.closeSubpath()
        case .home:
            p.move(to: CGPoint(x: 12, y: 3))
            p.addLine(to: CGPoint(x: 21, y: 10.5))
            p.addLine(to: CGPoint(x: 21, y: 21))
            p.addLine(to: CGPoint(x: 14.5, y: 21))
            p.addLine(to: CGPoint(x: 14.5, y: 14.5))
            p.addLine(to: CGPoint(x: 9.5, y: 14.5))
            p.addLine(to: CGPoint(x: 9.5, y: 21))
            p.addLine(to: CGPoint(x: 3, y: 21))
            p.addLine(to: CGPoint(x: 3, y: 10.5))
            p.closeSubpath()
        case .grid:
            p.addRoundedRect(in: CGRect(x: 3, y: 3, width: 8, height: 8), cornerSize: CGSize(width: 2.5, height: 2.5))
            p.addRoundedRect(in: CGRect(x: 13, y: 3, width: 8, height: 8), cornerSize: CGSize(width: 2.5, height: 2.5))
            p.addRoundedRect(in: CGRect(x: 3, y: 13, width: 8, height: 8), cornerSize: CGSize(width: 2.5, height: 2.5))
            p.addRoundedRect(in: CGRect(x: 13, y: 13, width: 8, height: 8), cornerSize: CGSize(width: 2.5, height: 2.5))
        case .person:
            p.addEllipse(in: CGRect(x: 7.5, y: 2.5, width: 9, height: 9))
            p.addArc(center: CGPoint(x: 12, y: 22), radius: 8, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            p.closeSubpath()
        case .alert:
            p.move(to: CGPoint(x: 12, y: 2))
            p.addLine(to: CGPoint(x: 22.5, y: 20.5))
            p.addLine(to: CGPoint(x: 1.5, y: 20.5))
            p.closeSubpath()
            p.addEllipse(in: CGRect(x: 11, y: 9, width: 2, height: 6))
            p.addEllipse(in: CGRect(x: 11, y: 16.6, width: 2, height: 2))
        case .cauldron:
            // Bowl + rim + two legs, with a bubble rising out of it.
            p.addEllipse(in: CGRect(x: 3.5, y: 8.5, width: 17, height: 3.4))
            p.move(to: CGPoint(x: 4.2, y: 10.6))
            p.addCurve(
                to: CGPoint(x: 19.8, y: 10.6),
                control1: CGPoint(x: 5.4, y: 21.4),
                control2: CGPoint(x: 18.6, y: 21.4)
            )
            p.closeSubpath()
            p.addRect(CGRect(x: 5.6, y: 19.6, width: 2.2, height: 3.4))
            p.addRect(CGRect(x: 16.2, y: 19.6, width: 2.2, height: 3.4))
            p.addEllipse(in: CGRect(x: 10.6, y: 2.4, width: 3.4, height: 3.4))
            p.addEllipse(in: CGRect(x: 14.2, y: 5.2, width: 2, height: 2))
        case .chips:
            // Three stacked casino chips, seen edge-on.
            p.addEllipse(in: CGRect(x: 3, y: 3.5, width: 18, height: 5.2))
            p.addRect(CGRect(x: 3, y: 6.1, width: 18, height: 3.2))
            p.addEllipse(in: CGRect(x: 3, y: 9.4, width: 18, height: 5.2))
            p.addRect(CGRect(x: 3, y: 12, width: 18, height: 3.2))
            p.addEllipse(in: CGRect(x: 3, y: 15.3, width: 18, height: 5.2))
        case .portal:
            // Portal rings around a lit core: the wheel in miniature, so the
            // tile reads as this game and not a generic dial.
            ringPath(&p, radius: 10.5, thickness: 2.2)
            ringPath(&p, radius: 6.8, thickness: 1.4)
            p.addEllipse(in: CGRect(x: 9.6, y: 9.6, width: 4.8, height: 4.8))
        case .wifiOff:
            p.addArc(center: CGPoint(x: 12, y: 18.5), radius: 2.2, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            p.move(to: CGPoint(x: 4.5, y: 4.5))
            p.addLine(to: CGPoint(x: 19.5, y: 19.5))
            p.addLine(to: CGPoint(x: 18.2, y: 20.8))
            p.addLine(to: CGPoint(x: 3.2, y: 5.8))
            p.closeSubpath()
        }
        return p
    }

    /// One annulus.
    ///
    /// The inner edge is traced backwards so the default non-zero fill rule
    /// leaves it hollow: two nested ellipses wound the same way would fill as
    /// a solid disc, which is how a portal ends up looking like a full stop.
    private func ringPath(_ p: inout Path, radius: CGFloat, thickness: CGFloat) {
        let centre = CGPoint(x: 12, y: 12)
        p.move(to: CGPoint(x: centre.x + radius, y: centre.y))
        p.addArc(center: centre, radius: radius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        p.move(to: CGPoint(x: centre.x + radius - thickness, y: centre.y))
        p.addArc(center: centre, radius: radius - thickness, startAngle: .degrees(360), endAngle: .zero, clockwise: true)
        p.closeSubpath()
    }

    private func starPath(_ p: inout Path, center: CGPoint, outer: CGFloat, inner: CGFloat, points: Int) {
        let step = CGFloat.pi * 2 / CGFloat(points * 2)
        for i in 0..<(points * 2) {
            let r = i % 2 == 0 ? outer : inner
            let angle = CGFloat(i) * step - .pi / 2
            let pt = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
    }
}

// MARK: - Static icon view

public struct NQIconView: View {
    private let icon: NQIcon
    private let tint: Color

    public init(icon: NQIcon, tint: Color = NQTheme.ink) {
        self.icon = icon
        self.tint = tint
    }

    public var body: some View {
        icon.path
            .fill(tint)
            .frame(width: 24, height: 24)
    }
}

// MARK: - Animated icon view

/// Motion is one-shot and interaction-driven, never a permanent idle loop:
/// premium products keep screens calm and save expressive motion for rewards.
public struct NQAnimatedIconView: View {
    private let icon: NQIcon
    private let tint: Color
    @State private var bounced = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(icon: NQIcon, tint: Color = NQTheme.ink) {
        self.icon = icon
        self.tint = tint
    }

    public var body: some View {
        base
            .scaleEffect(bounced && !reduceMotion ? 1.12 : 1)
            // Single settle-in pop on appear; no repeatForever, and the
            // rebound is cancelled with the view rather than firing into it.
            .task {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { bounced = true }
                try? await Task.sleep(nanoseconds: 300_000_000)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { bounced = false }
            }
    }

    private var base: some View {
        icon.path
            .fill(tint)
            .frame(width: NQLayout.iconXL, height: NQLayout.iconXL)
    }
}

// MARK: - Animated tab icon (bounce on select)

public struct NQTabIcon: View {
    private let icon: NQIcon
    private let selected: Bool
    @State private var bounce = false

    @Environment(\.nqAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(icon: NQIcon, selected: Bool) {
        self.icon = icon
        self.selected = selected
    }

    public var body: some View {
        // NQIconView fills its path with an explicit tint, so the color must
        // be passed in — an outer foregroundStyle has no effect.
        NQIconView(icon: icon, tint: selected ? accent.accent : NQTheme.inkFaint)
            .scaleEffect(bounce && !reduceMotion ? 1.25 : 1)
            .onChange(of: selected) { isSel in
                if isSel { NQHaptic.selection() }
            }
            .task(id: selected) {
                guard selected, !reduceMotion else { return }
                bounce = false
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { bounce = true }
                try? await Task.sleep(nanoseconds: 250_000_000)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { bounce = false }
            }
    }
}

// MARK: - Count-up ticker

/// Animates a number counting up whenever `value` changes.
public struct NQCountUpText: View {
    private let value: Int
    private let font: Font
    private let color: Color
    /// Counts up from zero the first time it appears. Off by default — a
    /// stat that is simply *being displayed* should not animate every time
    /// its screen is opened; a reward being *awarded* should.
    private let countsOnAppear: Bool
    @State private var displayValue: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        value: Int,
        font: Font = NQFont.heading.font(17),
        color: Color = NQTheme.ink,
        countsOnAppear: Bool = false
    ) {
        self.value = value
        self.font = font
        self.color = color
        self.countsOnAppear = countsOnAppear
        _displayValue = State(initialValue: countsOnAppear ? 0 : value)
    }

    public var body: some View {
        Text("\(displayValue)")
            .font(font)
            .foregroundStyle(color)
            .contentTransition(.numericText())
            .monospacedDigit()
            .onChange(of: value) { newValue in
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    displayValue = newValue
                }
            }
            .task {
                guard countsOnAppear, displayValue != value else { return }
                guard !reduceMotion else { displayValue = value; return }
                withAnimation(.spring(response: 0.8, dampingFraction: 0.9)) {
                    displayValue = value
                }
            }
    }
}

// MARK: - Heart burst (favorite)

public struct NQHeartBurst: View {
    @State private var filled = false
    @State private var burst = false
    @State private var wobble = false
    @State private var bursts = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Button {
            filled.toggle()
            NQHaptic.medium()
            guard filled, !reduceMotion else { return }
            bursts += 1
        } label: {
            ZStack {
                if burst {
                    ForEach(0..<6, id: \.self) { i in
                        Circle()
                            .fill(NQTheme.blush)
                            .frame(width: 5, height: 5)
                            .offset(
                                x: burst ? cos(CGFloat(i) / 6 * 2 * .pi) * 30 : 0,
                                y: burst ? sin(CGFloat(i) / 6 * 2 * .pi) * 30 : 0
                            )
                            .opacity(burst ? 0 : 1)
                    }
                }
                NQIcon.heart.view
                    .foregroundStyle(filled ? NQTheme.blush : NQTheme.inkFaint)
                    .scaleEffect(wobble ? 1.3 : 1)
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .task(id: bursts) {
            guard bursts > 0, !reduceMotion else { return }
            burst = false
            withAnimation(.spring(response: 0.25, dampingFraction: 0.5)) { wobble = true }
            withAnimation(.easeOut(duration: 0.6)) { burst = true }
            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { wobble = false }
            try? await Task.sleep(nanoseconds: 350_000_000)
            burst = false
        }
        .accessibilityLabel(filled ? "Remove favorite" : "Add favorite")
    }
}

// MARK: - Flame pulse (streak)

public struct NQFlamePulse: View {
    private let count: Int
    @State private var pulsing = false
    @State private var running = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        HStack(spacing: 6) {
            NQIcon.flame.view
                .foregroundStyle(NQTheme.flame)
                .scaleEffect(pulsing && running && !reduceMotion ? 1.08 : 1)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                    value: pulsing
                )
            NQCountUpText(value: count, font: NQFont.body.font(13))
        }
        .nqPadding(.chip)
        .nqPlate(NQTicketShape(), fill: NQTheme.background, elevation: .card)
        .onAppear { running = true; pulsing = true }
        .onDisappear { running = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) day streak")
    }
}

// MARK: - Confetti (legendary pull)

public struct NQConfetti: View {
    private var trigger: Int
    @State private var pieces: [ConfettiPiece] = []
    @State private var cleanupTrigger = 0

    public init(trigger: Int) {
        self.trigger = trigger
    }

    public var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(piece.color)
                    .frame(width: piece.size, height: piece.size * 1.6)
                    .rotationEffect(.degrees(piece.rotation))
                    .position(piece.position)
                    .opacity(piece.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _ in fire() }
        .onAppear { if trigger > 0 { fire() } }
        // Sweep the pieces on a cancellable task: a burst fired as a screen
        // dismisses shouldn't leave 36 views parked in memory.
        .task(id: cleanupTrigger) {
            guard cleanupTrigger > 0 else { return }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            pieces = []
        }
        .onDisappear { pieces = [] }
    }

    private struct ConfettiPiece: Identifiable {
        let id = UUID()
        var position: CGPoint
        var color: Color
        var size: CGFloat
        var rotation: Double
        var opacity: Double
    }

    private func fire() {
        #if canImport(UIKit)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: \.isKeyWindow) else { return }
        let size = window.bounds.size
        #else
        let size = CGSize(width: 400, height: 800)
        #endif
        let colors: [Color] = [NQTheme.gold, NQTheme.blush, NQTheme.success, NQTheme.info, NQRarity.epic.outline]
        pieces = (0..<36).map { i in
            ConfettiPiece(
                position: CGPoint(x: size.width / 2, y: -20),
                color: colors[i % colors.count],
                size: 6 + CGFloat(i % 4) * 2,
                rotation: Double(i) * 37,
                opacity: 1
            )
        }
        for i in pieces.indices {
            let targetX = size.width * CGFloat.random(in: 0.1...0.9)
            let targetY = size.height * CGFloat.random(in: 0.4...0.95)
            withAnimation(.easeIn(duration: Double.random(in: 1.2...2.0))) {
                pieces[i].position = CGPoint(x: targetX, y: targetY)
                pieces[i].rotation += Double.random(in: 180...720)
                pieces[i].opacity = 0
            }
        }
        cleanupTrigger += 1
    }
}
