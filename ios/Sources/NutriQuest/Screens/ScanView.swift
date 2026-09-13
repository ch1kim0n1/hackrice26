import SwiftUI
import NutriQuestUI

struct ScanView: View {
    @ObservedObject var gameState: GameState

    @State private var isScanning = false
    /// What the server answered for the barcode — drives the product card.
    /// `summonedCharacter` is non-nil only when the server minted.
    @State private var scanResult: ScanResultDTO?
    @State private var summonedCharacter: Character?
    @State private var errorMessage: String?
    @State private var isLookingUp = false
    @State private var summonStage: SummonStage = .hidden
    @State private var showPhotoCapture = false
    @State private var isAnalyzingMeal = false
    /// The draft breakdown awaiting the user's review. Non-nil drives the
    /// review sheet; nothing is logged until it's confirmed.
    @State private var dishAnalysis: DishAnalysisDTO?
    @State private var isConfirmingDish = false
    /// Totals of the last plate actually logged, for the summary card.
    @State private var lastPlate: DishTotalsDTO?

    /// The signature moment: scan lock → silhouette → rarity burst → reveal.
    enum SummonStage: Equatable {
        case hidden, lock, silhouette, rarity, reveal
    }

    @Environment(\.nqAccent) private var accent

    private let service = FoodDataService.shared

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
                } else if scanResult?.duplicate == true {
                    NQBanner("Already scanned: logged as a meal, but this barcode's monster is already yours.", dotColor: NQTheme.info)
                        .transition(NQTransition.pop)
                }

                if let scanResult {
                    productCard(scanResult)
                }

                if let errorMessage {
                    NQBanner.error(errorMessage, onDismiss: { self.errorMessage = nil })
                        .transition(NQTransition.pop)
                }

                if !isScanning {
                    VStack(spacing: NQTheme.spaceS) {
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

                        mealPhotoEntry
                    }
                }
            }
            .padding(NQTheme.spaceL)
        }
        .nqPageBackground()
        .navigationTitle("Scan")
        .navigationBarTitleDisplayMode(.inline)
        .nqTransparentNav()
        .toolbar {
            ToolbarItem(placement: .principal) {
                NQGameTitle("Scan")
            }
        }
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
                isConfirming: isConfirmingDish,
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
        DetectingPill()
    }

    private func productCard(_ result: ScanResultDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.foodName)
                .font(NQText.heading.font)
                .foregroundStyle(NQTheme.ink)
            if let score = result.nutritionScore {
                Text("Nutrition score \(Int(score.rounded()))")
                    .font(NQText.caption.font)
                    .foregroundStyle(NQTheme.inkSubtle)
            }
            if let n = result.nutrition {
                Text("Protein \(Int(n.proteinG ?? 0))g · Fiber \(Int(n.fiberG ?? 0))g · Sugar \(Int(n.sugarG ?? 0))g")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .nqPadding(.card)
        .nqSurface(.sticker)
        .accessibilityElement(children: .combine)
    }

    /// The barcode path — server-authoritative: `POST /scan` fetches the
    /// nutrition from Open Food Facts itself, scores it, and mints a ★1
    /// catalog monster the first time this player ever scans the barcode.
    /// A best-effort local OFF lookup enriches the day log (food group,
    /// micro score) but never decides anything.
    private func handleScan(_ payload: String, _ symbology: String?) {
        isScanning = false
        isLookingUp = true
        Task {
            do {
                let result = try await APIClient.shared.scanBarcode(payload)
                let product = try? await service.lookup(barcode: payload)
                isLookingUp = false
                scanResult = result
                if let character = gameState.registerScanResult(result, product: product) {
                    summonedCharacter = character
                    playSummonSequence()
                }
            } catch APIError.badStatus(let code, _) where code == 404 {
                isLookingUp = false
                errorMessage = "Product not found in Open Food Facts. Try another barcode."
            } catch APIError.badStatus(let code, _) where code == 422 {
                isLookingUp = false
                errorMessage = "That product's nutrition data failed sanity checks: nothing was logged or summoned."
            } catch {
                isLookingUp = false
                errorMessage = "Scan failed: \(error.localizedDescription). Check your connection and try again."
            }
        }
    }

    private func handleUnavailable(_ message: String) {
        isScanning = false
        errorMessage = message + " Try again on a real iPhone."
    }

    /// Staged reveal: lock (haptic) → silhouette → rarity burst → full reveal.
    private func playSummonSequence() {
        summonStage = .lock
        NQJuice.reveal()
        withAnimation(.easeOut(duration: 0.25)) {}
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
                .overlay {
                    RoundedRectangle(cornerRadius: NQTheme.radiusXL + 8)
                        .strokeBorder(NQTheme.inkDeep, lineWidth: 3)
                }
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

    /// Photo path: camera → analysis → **review** → meal log.
    /// Nothing is logged until the user has checked the breakdown — and a
    /// photo never mints a monster. Barcode is the only food path that can.
    private var mealPhotoEntry: some View {
        NQButton("No barcode? Snap your plate", icon: .sparkle, style: .secondary) {
            errorMessage = nil
            showPhotoCapture = true
        }
        .accessibilityHint("Take a photo of your meal. You'll see what was found and can fix it before logging.")
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
    /// recomputes the totals and logs the meal — a photo never mints.
    private func confirmDish(analysis: DishAnalysisDTO, edits: [DishItemEdit]) {
        isConfirmingDish = true
        Task {
            do {
                let result = try await APIClient.shared.confirmDishPhoto(
                    analysisId: analysis.analysisId,
                    edits: edits
                )
                lastPlate = result.nutrition
                dishAnalysis = nil
                gameState.registerDishLog(result: result)
                if result.flagged == true {
                    errorMessage = "Logged: heads up, this one was a rough estimate. You can double-check it in your meal log."
                }
            } catch {
                errorMessage = "Couldn't log that plate: \(error.localizedDescription)"
                // Keep dishAnalysis: a failed confirm leaves the review on
                // screen so the user can retry instead of re-shooting.
            }
            isConfirmingDish = false
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
        .background(NQTicketShape().fill(tint.opacity(0.12)))
        .overlay { NQTicketShape().strokeBorder(tint.opacity(0.5), lineWidth: 1.5) }
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
                        .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .transition(.scale(scale: 1.6).combined(with: .opacity))
    }

    private var silhouette: some View {
        VStack(spacing: NQTheme.spaceM) {
            NQAssetImage("unknown-characters")
            .frame(width: 150, height: 195)
            Text("Something is emerging…")
                .font(NQText.caption.font.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .transition(.scale(scale: 0.4).combined(with: .opacity))
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
                .transition(.scale(scale: 0.4).combined(with: .opacity))
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
            // The spec's summon card: Health, Attack, rarity, ★1, net worth.
            HStack(spacing: NQTheme.spaceS) {
                NQChip(rarityLabel, tint: rarityColor, filled: true)
                NQChip("★\(character.starLevel)", icon: .star, tint: NQTheme.gold, filled: true)
            }
            HStack(spacing: NQTheme.spaceS) {
                NQChip("HP \(Int(character.baseHealth.rounded()))", icon: .heart, tint: NQTheme.flame)
                NQChip("ATK \(Int(character.baseAttack.rounded()))", icon: .battle, tint: NQTheme.warning)
                if let mana = character.baseMana {
                    NQChip("Mana \(Int(mana.rounded()))", icon: .droplet, tint: NQTheme.info)
                }
            }
            NQChip("Net worth \(character.netWorth) coins", icon: .trophy, tint: NQTheme.gold)
        }
        .transition(.scale(scale: 0.7).combined(with: .opacity))
    }

    private var rarityLabel: String { character.rarity.label.uppercased() }
    private var rarityColor: Color { character.rarity.kitRarity.outline }
}

private struct DetectingPill: View {
    @Environment(\.nqAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: NQTheme.spaceS) {
            Circle()
                .fill(accent.accent)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse && !reduceMotion ? 1.25 : 0.85)
            Text("Detecting barcode…")
                .font(NQText.captionS.font.weight(.bold))
                .foregroundStyle(accent.accentDark)
        }
        .nqPadding(.chip)
        .background(NQPanelShape(cut: NQTheme.radiusS).fill(accent.accentBg))
        .overlay {
            NQPanelShape(cut: NQTheme.radiusS).strokeBorder(accent.accent.opacity(0.45), lineWidth: 1)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityElement(children: .combine)
    }
}
