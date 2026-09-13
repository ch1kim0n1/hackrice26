import SwiftUI
import NutriQuestUI

struct ScanView: View {
    @ObservedObject var gameState: GameState

    @State private var isScanning = false
    @State private var lookupResult: FoodProduct?
    @State private var summonedCharacter: Character?
    @State private var errorMessage: String?
    @State private var isLookingUp = false
    @State private var summonStage: SummonStage = .hidden
    @State private var showPhotoCapture = false
    @State private var isAnalyzingMeal = false
    /// The draft breakdown awaiting the user's review. Non-nil drives the
    /// review sheet; nothing is minted until it's confirmed.
    @State private var dishAnalysis: DishAnalysisDTO?
    @State private var isSummoningDish = false
    /// Totals of the last plate actually logged, for the summary card.
    @State private var lastPlate: DishTotalsDTO?

    /// The signature moment: scan lock → silhouette → rarity burst → reveal.
    enum SummonStage: Equatable {
        case hidden, lock, silhouette, rarity, reveal
    }

    @Environment(\.nqAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let service = FoodDataService.shared
    private let factory = CharacterFactory()

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceL) {
                ZStack {
                    viewfinder
                    if isScanning {
                        ScannerView(onScan: handleScan, onUnavailable: handleUnavailable)
                            .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusXL + 8))
                    }
                }
                .frame(height: 300)
                .accessibilityLabel(isScanning ? "Camera scanning for barcodes" : "Barcode scanner ready")

                if isScanning {
                    detectingPill
                } else if isLookingUp {
                    HStack(spacing: NQTheme.spaceS) {
                        NQDotsLoader(color: accent.accentDark)
                        Text("Looking up product…")
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                    }
                    .accessibilityElement(children: .combine)
                }

                if isAnalyzingMeal {
                    HStack(spacing: NQTheme.spaceS) {
                        NQDotsLoader(color: accent.accentDark)
                        Text("Analyzing your meal…")
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                    }
                    .accessibilityElement(children: .combine)
                }

                if let lastPlate {
                    mealNutritionCard(lastPlate)
                        .transition(NQTransition.pop)
                }

                if let summonedCharacter, summonStage == .reveal {
                    NQBanner("Summoned: **\(summonedCharacter.name)**", dotColor: accent.accent)
                        .transition(NQTransition.pop)
                }

                if let lookupResult {
                    productCard(lookupResult)
                }

                if let errorMessage {
                    NQBanner.error(errorMessage, onDismiss: { self.errorMessage = nil })
                        .transition(NQTransition.pop)
                }

                if !isScanning {
                    NQButton(isLookingUp ? "Looking up…" : "Start Scanning", icon: .barcode) {
                        errorMessage = nil
                        guard ScannerView.isSupported, ScannerView.isAvailable else {
                            errorMessage = ScannerView.isSupported
                                ? "Camera permission is needed to scan. Enable it in Settings and try again."
                                : "This device can't scan barcodes."
                            return
                        }
                        isScanning = true
                    }
                    .disabled(isLookingUp)
                    .accessibilityHint("Opens the camera to scan a food barcode.")
                }
            }
            .padding(NQTheme.spaceL)
        }
        .nqPageBackground()
        .navigationTitle("Scan Food")
        .navigationBarTitleDisplayMode(.inline)
        .animation(NQMotion.springy, value: summonedCharacter)
        .animation(NQMotion.quick, value: errorMessage)
        .sheet(isPresented: $showPhotoCapture) {
            MealPhotoCapture(
                onCapture: handleMealPhoto,
                onCancel: { showPhotoCapture = false }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $dishAnalysis) { analysis in
            DishReviewView(
                analysis: analysis,
                isSummoning: isSummoningDish,
                onConfirm: { edits in confirmDish(analysis: analysis, edits: edits) },
                onRetake: {
                    dishAnalysis = nil
                    showPhotoCapture = true
                }
            )
        }
        .overlay {
            if let character = summonedCharacter, summonStage != .hidden {
                SummonRevealOverlay(
                    character: character,
                    stage: summonStage,
                    onDismiss: {
                        summonStage = .hidden
                        summonedCharacter = nil
                    }
                )
                .transition(.opacity)
            }
        }
    }

    private var detectingPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(accent.accent)
                .frame(width: 7, height: 7)
            Text("Detecting barcode…")
                .font(NQText.captionS.font.weight(.bold))
                .foregroundStyle(accent.accentDark)
        }
        .nqPadding(.badge)
        .padding(.horizontal, 6)
        .background(Capsule().fill(accent.accentBg))
        .accessibilityElement(children: .combine)
    }

    private func productCard(_ product: FoodProduct) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(product.displayName)
                .font(NQText.heading.font)
                .foregroundStyle(NQTheme.ink)
            if let brands = product.brands {
                Text(brands)
                    .font(NQText.caption.font)
                    .foregroundStyle(NQTheme.inkSubtle)
            }
            if let nutriments = product.nutriments {
                Text("Protein \(nutriments.proteins100g ?? 0)g · Fiber \(nutriments.fiber100g ?? 0)g · Sugar \(nutriments.sugars100g ?? 0)g")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nqPadding(.card)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusM), elevation: .soft)
        .accessibilityElement(children: .combine)
    }

    private func handleScan(_ payload: String, _ symbology: String?) {
        isScanning = false
        isLookingUp = true
        Task {
            do {
                let product = try await service.lookup(barcode: payload)
                isLookingUp = false
                guard let product else {
                    errorMessage = "Product not found in Open Food Facts. Try another barcode."
                    return
                }
                lookupResult = product
                summonedCharacter = gameState.registerScan(product: product, barcode: payload)
                playSummonSequence()
            } catch {
                isLookingUp = false
                errorMessage = "Lookup failed: \(error.localizedDescription). Check your connection and try again."
            }
        }
    }

    private func handleUnavailable(_ message: String) {
        isScanning = false
        errorMessage = message + " Try again on a real iPhone."
    }

    /// Staged reveal: lock (haptic) → silhouette → rarity burst → full reveal.
    ///
    /// Under Reduce Motion the staging is the whole point of what gets
    /// skipped — the suspense is the motion. The character still arrives, and
    /// still with its haptic/sound cue (those have their own setting), just
    /// without the 1.9s build.
    private func playSummonSequence() {
        NQJuice.reveal()
        guard !reduceMotion else {
            summonStage = .reveal
            NQJuice.success()
            return
        }
        summonStage = .lock
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { summonStage = .silhouette }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { summonStage = .rarity }
            NQJuice.success()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.65)) { summonStage = .reveal }
        }
    }

    /// Viewfinder per the mockup: dark rounded panel, accent corner brackets,
    /// barcode glyph, scan beam while active.
    private var viewfinder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NQTheme.radiusXL + 8)
                .fill(
                    LinearGradient(colors: [NQTheme.chrome, NQTheme.inkDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(height: 300)
                .nqElevation(.raised)

            if !isScanning {
                NQAssetImage("scan-frame-ink")
                    .padding(NQTheme.spaceM)
            } else {
                NQAssetImage("scan-frame-locked-on")
                    .padding(NQTheme.spaceM)
            }

            if isScanning {
                NQScanBeam(beamColor: accent.accent)
                    .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusXL + 8))
            }
        }
    }

    // MARK: - Dish photo (no barcode)

    /// Photo path: camera → analysis → **review** → character.
    /// Nothing is minted until the user has checked the breakdown, which is
    /// what makes a photo-only estimate trustworthy enough to keep forever.
    private var mealPhotoEntry: some View {
        NQButton("No barcode? Snap your plate", icon: .sparkle, style: .secondary) {
            errorMessage = nil
            showPhotoCapture = true
        }
        .accessibilityHint("Take a photo of your meal. You'll see what was found and can fix it before summoning.")
    }

    /// Step 1: analyse the photo. This only produces a draft breakdown.
    private func handleMealPhoto(_ image: UIImage) {
        showPhotoCapture = false
        isAnalyzingMeal = true
        Task {
            do {
                guard let jpeg = image.jpegData(compressionQuality: 0.55) else {
                    throw APIError.invalidURL("image encoding")
                }
                dishAnalysis = try await APIClient.shared.analyzeDishPhoto(
                    jpegBase64: jpeg.base64EncodedString()
                )
            } catch {
                errorMessage = "Couldn't read that plate: \(error.localizedDescription)"
            }
            isAnalyzingMeal = false
        }
    }

    /// Step 2: the user confirmed (possibly after corrections). The server
    /// recomputes the totals and mints the character.
    private func confirmDish(analysis: DishAnalysisDTO, edits: [DishItemEdit]) {
        isSummoningDish = true
        Task {
            do {
                let result = try await APIClient.shared.confirmDishPhoto(
                    analysisId: analysis.analysisId,
                    edits: edits
                )
                lastPlate = result.nutrition
                dishAnalysis = nil
                if let character = gameState.registerDish(result: result) {
                    summonedCharacter = character
                    playSummonSequence()
                }
            } catch {
                errorMessage = "Couldn't log that plate: \(error.localizedDescription)"
                // Keep dishAnalysis: a failed confirm leaves the review on
                // screen so the user can retry instead of re-shooting.
            }
            isSummoningDish = false
        }
    }

    private func mealNutritionCard(_ n: DishTotalsDTO) -> some View {
        NQCard {
            VStack(alignment: .leading, spacing: NQTheme.spaceS) {
                HStack {
                    Text("Logged plate")
                        .font(NQText.caption.font.weight(.bold))
                        .foregroundStyle(NQTheme.inkMuted)
                    Spacer()
                    Text("\(Int(n.calories)) kcal")
                        .font(NQText.heading.font)
                        .foregroundStyle(accent.accentDark)
                }
                HStack(spacing: NQTheme.spaceM) {
                    nutrientPill("P", value: n.proteinG, unit: "g", tint: NQTheme.flame)
                    nutrientPill("F", value: n.fiberG, unit: "g", tint: NQTheme.success)
                    nutrientPill("C", value: n.carbsG, unit: "g", tint: NQTheme.info)
                    nutrientPill("S", value: n.sugarG, unit: "g", tint: NQTheme.warning)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Logged plate: \(Int(n.calories)) kilocalories")
    }

    private func nutrientPill(_ label: String, value: Double, unit: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(NQText.micro.font.weight(.bold)).foregroundStyle(tint)
            Text("\(Int(value))\(unit)").font(NQText.captionS.font).foregroundStyle(NQTheme.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusM))
    }

}

// MARK: - Summon reveal overlay (the signature moment)

/// Full-screen reveal: dark stage → silhouette → rarity burst → character
/// entrance with stat payoff. Tap to dismiss once revealed.
struct SummonRevealOverlay: View {
    let character: Character
    let stage: ScanView.SummonStage
    let onDismiss: () -> Void

    @Environment(\.nqAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.opacity(stage == .lock ? 0.25 : 0.72)
                .ignoresSafeArea()
                .animation(.easeOut(duration: 0.3), value: stage)

            VStack(spacing: NQTheme.spaceL) {
                Spacer()
                stageContent
                Spacer()
                if stage == .reveal {
                    NQButton("Added to squad, let's go", icon: .checkCircle) { onDismiss() }
                        .padding(.horizontal, NQTheme.spaceXL)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.vertical, NQTheme.spaceXL)

            if stage == .rarity || stage == .reveal {
                NQConfetti(trigger: 1)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if stage == .reveal { onDismiss() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Character summoned: \(character.name)")
    }

    /// Stages scale in normally; under Reduce Motion they cross-fade, so the
    /// reveal still reads as a distinct beat without the zoom.
    private func stageTransition(scale: CGFloat) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: scale).combined(with: .opacity)
    }

    @ViewBuilder private var stageContent: some View {
        switch stage {
        case .lock:
            lockFlash
        case .silhouette:
            silhouette
        case .rarity:
            rarityBurst
        case .reveal:
            revealCard
        case .hidden:
            EmptyView()
        }
    }

    private var lockFlash: some View {
        VStack(spacing: NQTheme.spaceM) {
            Circle()
                .fill(accent.accent)
                .frame(width: 90, height: 90)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 5))
                .shadow(color: accent.accent.opacity(0.7), radius: 24)
            Text("Locked on")
                .font(NQText.captionS.font.weight(.heavy))
                .tracking(0.8)
                .foregroundStyle(.white)
        }
        .transition(stageTransition(scale: 1.6))
    }

    private var silhouette: some View {
        VStack(spacing: NQTheme.spaceM) {
            NQAssetImage("unknown-characters")
            .frame(width: 150, height: 195)
            Text("Something is emerging…")
                .font(NQText.caption.font.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .transition(stageTransition(scale: 0.4))
    }

    private var rarityBurst: some View {
        VStack(spacing: NQTheme.spaceM) {
            ZStack {
                Circle()
                    .fill(rarityColor.opacity(0.35))
                    .frame(width: 240, height: 240)
                    .blur(radius: 30)
                CharacterArtwork(character: character, expression: .sparkle)
                .frame(width: 170, height: 220)
            }
            Text(rarityLabel.uppercased())
                .font(NQText.headingL.font.weight(.heavy))
                .tracking(1.2)
                .foregroundStyle(rarityColor)
                .transition(stageTransition(scale: 0.4))
        }
    }

    private var revealCard: some View {
        VStack(spacing: NQTheme.spaceM) {
            ZStack {
                Circle()
                    .fill(rarityColor.opacity(0.25))
                    .frame(width: 230, height: 230)
                    .blur(radius: 28)
                CharacterArtwork(character: character)
                    .frame(width: 170, height: 220)
            }
            Text(character.name)
                .font(NQText.displayL.font.weight(.heavy))
                .foregroundStyle(.white)
            HStack(spacing: NQTheme.spaceS) {
                NQChip(rarityLabel, tint: rarityColor, filled: true)
                NQChip(character.statType.label, icon: .leaf)
            }
        }
        .transition(stageTransition(scale: 0.7))
    }

    private var rarityLabel: String { character.rarity.label.uppercased() }
    private var rarityColor: Color { character.rarity.kitRarity.outline }
}
