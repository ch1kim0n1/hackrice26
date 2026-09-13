import SwiftUI

// MARK: - Character animation modes

/// Ambient animation applied to a chibi character.
public enum NQCharacterMotion: CaseIterable, Sendable {
    case idle          // gentle bob + squash-stretch
    case excited       // happy bounce (summon / level up)
    case sleepy        // slow breathing
    case talk          // mouth flap
    case sad           // droop
    case wave          // greeting wiggle
    case none
}

/// Wraps `ChibiCharacterView` with looping character motion.
public struct AnimatedChibi: View {
    private let color: NQCharacterColor
    private let statType: NQStatType
    private let expression: ChibiExpression
    private let motion: NQCharacterMotion

    @State private var t = false          // generic loop toggle
    @State private var blink = false      // eye blink
    @State private var nextBlink: Double = 2.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        color: NQCharacterColor,
        statType: NQStatType,
        expression: ChibiExpression = .happy,
        motion: NQCharacterMotion = .idle
    ) {
        self.color = color
        self.statType = statType
        self.expression = expression
        self.motion = motion
    }

    public var body: some View {
        let resolvedExpression: ChibiExpression = blink ? .sleepy : expression
        ChibiCharacterView(color: color, statType: statType, expression: resolvedExpression)
            .scaleEffect(scale, anchor: .bottom)
            .offset(y: offset)
            .rotationEffect(.degrees(rotation), anchor: .bottom)
            .animation(blink ? .linear(duration: 0.12) : motionAnimation, value: t)
            .onAppear { scheduleLoops() }
            .task(id: "blink") {
                guard !reduceMotion else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(nextBlink * 1_000_000_000))
                    withAnimation(.linear(duration: 0.1)) { blink = true }
                    try? await Task.sleep(nanoseconds: 140_000_000)
                    withAnimation(.linear(duration: 0.1)) { blink = false }
                    nextBlink = Double.random(in: 2.2...5.0)
                }
            }
    }

    private var motionAnimation: Animation {
        switch motion {
        case .excited: return .spring(response: 0.32, dampingFraction: 0.5)
        case .talk, .wave: return .easeInOut(duration: 0.24)
        case .sleepy: return .easeInOut(duration: 2.6)
        default: return .easeInOut(duration: 1.6)
        }
    }

    private var scale: CGFloat {
        guard t else { return baseScale }
        switch motion {
        case .idle: return baseScale * 1.02
        case .excited: return baseScale * 1.12
        case .sleepy: return baseScale * 0.985
        case .talk: return baseScale * 1.015
        case .sad: return baseScale * 0.96
        case .wave, .none: return baseScale
        }
    }

    private var offset: CGFloat {
        guard t else { return 0 }
        switch motion {
        case .idle: return -5
        case .excited: return -14
        case .sleepy: return 1
        case .sad: return 3
        case .talk, .wave, .none: return 0
        }
    }

    private var rotation: Double {
        guard t else { return 0 }
        switch motion {
        case .wave: return 4
        case .sad: return -2
        default: return 0
        }
    }

    private var baseScale: CGFloat { 1 }

    private func scheduleLoops() {
        switch motion {
        case .none:
            t = false
        default:
            if reduceMotion { t = false } else { withAnimation(motionAnimation) { t = true } }
        }
    }
}

// MARK: - Summon reveal

/// Summon reveal stages. Top-level (not nested in the generic struct) so
/// call sites can reference `NQSummonStage` without specializing Content.
public enum NQSummonStage { case hidden, materializing, revealed }

/// Full summon sequence: blur + scale materialize + particle burst + confetti
/// for legendary. Wrap the revealed character; drive with `stage`.
public struct NQSummonReveal<Content: View>: View {
    public typealias Stage = NQSummonStage

    private let stage: Stage
    private let rarity: NQRarity
    private let content: Content

    public init(stage: Stage, rarity: NQRarity, @ViewBuilder content: () -> Content) {
        self.stage = stage
        self.rarity = rarity
        self.content = content()
    }

    public var body: some View {
        ZStack {
            if stage != .hidden {
                content
                    .scaleEffect(stage == .materializing ? 0.3 : 1)
                    .blur(radius: stage == .materializing ? 14 : 0)
                    .opacity(stage == .materializing ? 0.4 : 1)
                    .animation(.spring(response: 0.55, dampingFraction: 0.62), value: stage)
            }
        }
    }
}

// MARK: - Scanning beam

/// Horizontal light beam sweeping vertically — barcode scanning feedback.
public struct NQScanBeam: View {
    @State private var y: CGFloat = -0.5
    private var beamColor: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(beamColor: Color = NQTheme.success) {
        self.beamColor = beamColor
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                LinearGradient(
                    colors: [beamColor.opacity(0), beamColor.opacity(0.7), beamColor.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 60)
                .offset(y: y * geo.size.height)
                Rectangle()
                    .fill(beamColor)
                    .frame(height: 2.5)
                    .shadow(color: beamColor, radius: 6)
                    .offset(y: y * geo.size.height)
            }
            .frame(width: geo.size.width)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                y = 1.1
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Skeleton shimmer

/// Shimmering placeholder block. Compose skeletons from these.
public struct NQSkeleton: View {
    private var width: CGFloat?
    private var height: CGFloat
    private var cornerRadius: CGFloat

    @State private var shimmering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(width: CGFloat? = nil, height: CGFloat, cornerRadius: CGFloat = NQTheme.radiusS) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(NQTheme.hairline)
            .frame(width: width, height: height)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.7), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.7)
                        .offset(x: shimmering ? geo.size.width : -geo.size.width * 0.7)
                        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: shimmering)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }
            }
            .onAppear { shimmering = true }
            .accessibilityLabel("Loading")
    }
}

/// Skeleton for a character card grid.
public struct NQCardSkeleton: View {
    public init() {}
    public var body: some View {
        VStack(spacing: 10) {
            NQSkeleton(width: 96, height: 96, cornerRadius: 20)
            NQSkeleton(height: 12)
            NQSkeleton(width: 60, height: 10)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .nqSurface(.sticker)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

// MARK: - Dots loader

public struct NQDotsLoader: View {
    private var color: Color
    @State private var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(color: Color = NQTheme.inkMuted) {
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .offset(y: animating && !reduceMotion ? -6 : 3)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.45)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Progress ring

/// Circular progress ring for daily goals.
public struct NQProgressRing: View {
    private let progress: Double       // 0...1
    private var lineWidth: CGFloat = 9
    private var trackColor: Color?
    private var fillColor: Color?

    @Environment(\.nqAccent) private var accent

    public init(progress: Double, lineWidth: CGFloat = 9, track: Color? = nil, fill: Color? = nil) {
        self.progress = min(max(progress, 0), 1)
        self.lineWidth = lineWidth
        self.trackColor = track
        self.fillColor = fill
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor ?? accent.accentSoft, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(fillColor ?? accent.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(NQMotion.fill, value: progress)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

// MARK: - Checkmark draw-on

/// Animated checkmark stroke — success feedback.
public struct NQCheckmarkDraw: View {
    private var color: Color
    private var size: CGFloat
    @State private var drawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(color: Color = NQTheme.success, size: CGFloat = 48) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.14))
            Circle()
                .stroke(color, lineWidth: 3)
                .scaleEffect(drawn ? 1 : 0.4)
                .opacity(drawn ? 1 : 0)
            CheckShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .padding(size * 0.28)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { drawn = true; return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { drawn = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Completed")
    }

    private struct CheckShape: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            return p
        }
    }
}
