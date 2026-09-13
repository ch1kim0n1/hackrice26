import SwiftUI

/// Live gallery of every animation, transition, state, and icon in the kit.
public struct NQAnimationDemoView: View {
    @State private var tab: NQTab = .home
    @State private var burstTrigger = 0
    @State private var confettiTrigger = 0
    @State private var shakeTrigger = 0
    @State private var progress: Double = 0.35
    @State private var selectedCard: Int? = 0
    @State private var editMode = false
    @State private var showSummon = false

    public init() {}

    public var body: some View {
        NQScreen(tab: $tab, trailing: { NQFlamePulse(count: 7) }) {
            ScrollView {
                VStack(alignment: .leading, spacing: NQTheme.spaceL) {

                    NQSectionHeader("Character motions")
                    characterMotions

                    NQSectionHeader("Entrances")
                    NQCard {
                        HStack(spacing: NQTheme.spaceM) {
                            NQButton("Pop-in", icon: .sparkle) { confettiTrigger += 1 }
                                .nqSuccessBurst(on: burstTrigger)
                            NQButton("Shake", icon: .alert, style: .secondary) {
                                shakeTrigger += 1
                                NQHaptic.error()
                            }
                            NQButton("Confetti", icon: .crown, style: .secondary) {
                                confettiTrigger += 1
                                NQHaptic.success()
                            }
                        }
                    }
                    .nqShake(on: shakeTrigger)

                    NQSectionHeader("Loading & progress")
                    NQCard {
                        VStack(alignment: .leading, spacing: NQTheme.spaceM) {
                            HStack(spacing: NQTheme.spaceL) {
                                NQDotsLoader(color: NQCharacterColor.blossom.accent)
                                NQCheckmarkDraw()
                                NQProgressRing(progress: progress)
                                    .frame(width: 52, height: 52)
                                    .onTapGesture {
                                        progress = progress >= 1 ? 0.1 : progress + 0.25
                                        NQHaptic.light()
                                    }
                                NQScanBeam()
                                    .frame(width: 90, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .background(NQTheme.surface)
                            }
                            HStack(spacing: NQTheme.spaceM) {
                                NQSkeleton(width: 80, height: 80, cornerRadius: 20)
                                VStack(alignment: .leading, spacing: 8) {
                                    NQSkeleton(height: 14)
                                    NQSkeleton(height: 10)
                                    NQSkeleton(width: 100, height: 10)
                                }
                            }
                        }
                    }

                    NQSectionHeader("Icons (animated)")
                    NQCard {
                        VStack(alignment: .leading, spacing: NQTheme.spaceM) {
                            HStack {
                                ForEach(NQIcon.allCases, id: \.self) { icon in
                                    icon.animated
                                        .foregroundStyle(NQCharacterColor.blossom.accentDark)
                                }
                            }
                            HStack {
                                ForEach(NQIcon.allCases, id: \.self) { icon in
                                    icon.view
                                        .foregroundStyle(NQTheme.inkMuted)
                                }
                            }
                            HStack(spacing: NQTheme.spaceL) {
                                NQHeartBurst()
                                NQHeartBurst()
                                NQHeartBurst()
                            }
                        }
                    }

                    NQSectionHeader("States")
                    NQCard {
                        VStack(alignment: .leading, spacing: NQTheme.spaceM) {
                            NQBanner.success("Snack scanned — Fibelle gained +12 protein!")
                            NQBanner.warning("Streak at risk — scan something today!")
                            NQBanner.error("Battle lost. Rematch?")
                            NQContentState(.offline(retry: {}))
                        }
                    }

                    NQSectionHeader("Cards & selection")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: NQTheme.spaceM) {
                        ForEach(0..<4, id: \.self) { i in
                            let colors: [NQCharacterColor] = [.mint, .sky, .blossom, .lilac]
                            let rarities: [NQRarity] = [.common, .rare, .epic, .legendary]
                            NQCharacterCard(
                                name: ["Fibelle", "Proteini", "Vitamina", "Hydra"][i],
                                color: colors[i],
                                rarity: rarities[i],
                                statType: [.fiber, .protein, .vitamin, .hydration][i],
                                state: selectedCard == i ? .active : (i == 3 ? .locked : .normal)
                            )
                            .nqSelectedGlow(selectedCard == i, color: colors[i].accent)
                            .nqWobble(editMode)
                            .nqLockedShimmer()
                            .onTapGesture {
                                selectedCard = i
                                NQHaptic.selection()
                            }
                            .nqCascade(index: i)
                        }
                    }
                    .nqShineSweep(active: selectedCard == 3)
                    Toggle("Edit mode (wobble)", isOn: $editMode)
                        .font(NQText.body.font)
                        .padding(.horizontal, 4)

                    NQSectionHeader("Legendary summon")
                    NQButton("Summon", icon: .sparkle) {
                        showSummon = true
                        confettiTrigger += 1
                    }
                }
                .padding()
                .padding(.bottom, NQTheme.spaceXL)
            }
        }
        .overlay {
            if showSummon {
                summonOverlay
            }
        }
        .nqAccentContext(NQAccentContext(mode: .active, character: .blossom))
    }

    private var characterMotions: some View {
        let motions: [(NQCharacterMotion, ChibiExpression)] = [
            (.idle, .happy), (.excited, .sparkle), (.sleepy, .sleepy), (.sad, .neutral)
        ]
        return NQCard {
            HStack {
                ForEach(Array(motions.enumerated()), id: \.offset) { _, pair in
                    AnimatedChibi(color: .blossom, statType: .vitamin, expression: pair.1, motion: pair.0)
                        .frame(width: 64, height: 84)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .nqSlideUp()
    }

    private var summonOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { showSummon = false }
            VStack(spacing: NQTheme.spaceM) {
                NQSummonReveal(stage: showSummon ? .revealed : .hidden, rarity: .legendary) {
                    AnimatedChibi(color: .lilac, statType: .hydration, expression: .sparkle, motion: .excited)
                        .frame(width: 160, height: 208)
                        .nqBreathingGlow(color: NQTheme.gold)
                }
                Text("HYDRA")
                    .font(NQText.displayL.font)
                    .foregroundStyle(NQTheme.ink)
                NQChip("Legendary", tint: NQRarity.legendary.outline, filled: true)
                NQButton("Nice!", style: .secondary, fullWidth: false) { showSummon = false }
            }
            .padding(NQTheme.spaceL)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
            .transition(NQTransition.summon)
        }
        .transition(.opacity)
        .zIndex(10)
    }
}

#Preview("Animation Demo") {
    NQAnimationDemoView()
}
