import SwiftUI

/// The actual crate/case artwork drops in, shakes, cracks open, and releases
/// its contents. Drives the reveal sequence for CrateOpeningView.
///
/// Stages:
///   .dropping    — case falls from above with bounce
///   .charging    — hold-to-open: rim glow + wobble build with `chargeProgress`
///   .shaking     — case vibrates, building tension
///   .cracking    — flash burst, closed art crossfades toward opened art
///   .open        — opened art settles, contents fully visible
///   .hidden      — nothing rendered
public enum NQCapsuleStage: Sendable {
    case hidden
    case dropping
    case charging
    case shaking
    case cracking
    case open
}

public struct NQCapsule<Content: View>: View {
    public let stage: NQCapsuleStage
    public let rarity: NQRarity
    /// 0...1 — drives the charge ring + wobble intensity while `.charging`.
    public let chargeProgress: Double
    private let content: Content
    /// The actual case/chest artwork, closed then opened — the reveal shows
    /// the crate itself, not just a generic capsule shape.
    private let closedArtwork: AnyView
    private let openedArtwork: AnyView

    @State private var shakeOffset: CGFloat = 0
    @State private var crackFlash = false
    @State private var dropOffset: CGFloat = -300
    @State private var dropScale: CGFloat = 0.5
    @State private var flashTrigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        stage: NQCapsuleStage,
        rarity: NQRarity,
        chargeProgress: Double = 0,
        closedArtwork: AnyView,
        openedArtwork: AnyView,
        @ViewBuilder content: () -> Content
    ) {
        self.stage = stage
        self.rarity = rarity
        self.chargeProgress = chargeProgress
        self.closedArtwork = closedArtwork
        self.openedArtwork = openedArtwork
        self.content = content()
    }

    public var body: some View {
        ZStack {
            switch stage {
            case .hidden:
                EmptyView()
            case .dropping, .charging, .shaking, .cracking, .open:
                capsuleView
            }
        }
        .onChange(of: stage) { newStage in
            handleStageChange(newStage)
        }
        .task(id: stage) {
            guard stage == .shaking, !reduceMotion else { return }
            await shakeSequence()
        }
        .task(id: flashTrigger) {
            guard flashTrigger > 0 else { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
            withAnimation(.easeIn(duration: 0.3)) { crackFlash = false }
        }
        .onDisappear { shakeOffset = 0 }
    }

    // MARK: - Capsule visual

    private var capsuleView: some View {
        ZStack {
            // Rarity-tinted glow behind capsule — swells while charging so a
            // hot pull literally radiates before the crack.
            if stage != .open {
                Circle()
                    .fill(rarity.outline.opacity(stage == .charging ? 0.15 + chargeProgress * 0.3 : 0.15))
                    .frame(width: 220 + chargeProgress * 40, height: 220 + chargeProgress * 40)
                    .blur(radius: 20 + chargeProgress * 12)
            }

            // Charge ring — the hold meter wrapping the capsule.
            if stage == .charging {
                Circle()
                    .stroke(rarity.outline.opacity(0.25), lineWidth: 5)
                    .frame(width: 190, height: 190)
                Circle()
                    .trim(from: 0, to: chargeProgress)
                    .stroke(
                        rarity.outline,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .frame(width: 190, height: 190)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.05), value: chargeProgress)
            }

            // Crack flash
            if crackFlash {
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 200, height: 200)
                    .blur(radius: 30)
                    .transition(.opacity)
            }

            caseArtwork

            // Contents (visible at .cracking and .open)
            if stage == .cracking || stage == .open {
                content
                    .scaleEffect(stage == .cracking ? 0.6 : 1.0)
                    .opacity(stage == .cracking ? 0.7 : 1.0)
                    .blur(radius: stage == .cracking ? 8 : 0)
                    .animation(.spring(response: 0.55, dampingFraction: 0.65), value: stage)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .offset(y: dropOffset)
        .scaleEffect(dropScale)
        .offset(x: shakeOffset)
        // Charging wobble: intensity scales with progress — calm to violent.
        .offset(x: stage == .charging ? sin(chargeProgress * .pi * 16) * 5 * chargeProgress : 0)
        .rotationEffect(.degrees(stage == .charging ? sin(chargeProgress * .pi * 10) * 3 * chargeProgress : 0))
    }

    /// The case itself: closed art through drop/charge/shake, crossfading to
    /// the opened art as it cracks. One image swap reads more like "your
    /// crate" than two vector halves ever did.
    private var caseArtwork: some View {
        ZStack {
            closedArtwork
                .opacity(stage == .open ? 0 : 1)
                .scaleEffect(stage == .cracking ? 1.12 : 1)
                .blur(radius: stage == .cracking ? 3 : 0)

            openedArtwork
                .opacity(stage == .open ? 1 : 0)
                .scaleEffect(stage == .open ? 1 : 0.75)
        }
        .frame(width: 168, height: 168)
        .shadow(color: rarity.outline.opacity(0.35), radius: 16, y: 8)
        .animation(.spring(response: 0.5, dampingFraction: 0.62), value: stage)
    }

    // MARK: - Stage transitions

    private func handleStageChange(_ newStage: NQCapsuleStage) {
        guard !reduceMotion else {
            // Skip animations for reduce-motion; jump to final state.
            if newStage == .open || newStage == .cracking {
                dropOffset = 0
                dropScale = 1.0
                shakeOffset = 0
            }
            return
        }

        switch newStage {
        case .hidden:
            dropOffset = -300
            dropScale = 0.5
            shakeOffset = 0
            crackFlash = false

        case .dropping:
            withAnimation(.spring(response: 0.6, dampingFraction: 0.55)) {
                dropOffset = 0
                dropScale = 1.0
            }

        case .charging:
            // Landed and waiting for the hold — no scripted motion; the wobble
            // is driven by chargeProgress so it is always in sync with input.
            shakeOffset = 0

        case .shaking:
            break   // the shake runs on the `.task(id: stage)` below

        case .cracking:
            withAnimation(.easeOut(duration: 0.15)) { crackFlash = true }
            flashTrigger += 1

        case .open:
            break   // the artwork crossfade is driven by `caseArtwork`'s own animation
        }
    }

    /// Sustained vibration while `.shaking`: a series of bursts, each a
    /// little wider than the last, so longer suspense keeps the capsule
    /// visibly tense.
    ///
    /// Driven by a cancellable task rather than a queue of `asyncAfter`
    /// calls: closing the crate mid-suspense used to leave four scheduled
    /// bursts firing into a view that no longer existed.
    private func shakeSequence() async {
        let bursts: [(offset: CGFloat, count: Int, pause: UInt64)] = [
            (6, 8, 500_000_000),
            (-5, 10, 600_000_000),
            (7, 12, 700_000_000),
            (-6, 14, 800_000_000),
            (8, 16, 0)
        ]
        for burst in bursts {
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.05).repeatCount(burst.count, autoreverses: true)) {
                shakeOffset = burst.offset
            }
            guard burst.pause > 0 else { break }
            try? await Task.sleep(nanoseconds: burst.pause)
        }
    }
}
