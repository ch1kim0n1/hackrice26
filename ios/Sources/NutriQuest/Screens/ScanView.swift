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
    /// Camera access was refused — surfaces a shortcut into Settings.
    @State private var cameraDenied = false
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

                if cameraDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    NQButton("Open Settings", sfSymbol: "gear", style: .ghost) {
                        UIApplication.shared.open(settings)
                    }
                    .accessibilityHint("Opens the Settings app so you can allow camera access.")
                }

                if !isScanning {
                    VStack(spacing: NQTheme.spaceS) {
                        NQButton(isLookingUp ? "Looking up…" : "Start Scanning", icon: .barcode) {
                            startScanning()
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

    /// The nutrition the server extracted for this barcode. Figures are per
    /// 100 g — the same snapshot the NutritionScore and the mint were drawn
    /// from — so the card says so rather than implying a serving.
    private func productCard(_ result: ScanResultDTO) -> some View {
        NQCard {
            VStack(alignment: .leading, spacing: NQTheme.spaceS) {
                HStack(alignment: .firstTextBaseline, spacing: NQTheme.spaceS) {
                    VStack(alignment: .leading, spacing: NQTheme.spaceXS) {
                        Text(result.foodName)
                            .font(NQText.heading.font)
                            .foregroundStyle(NQTheme.ink)
                        if let brands = result.brands, !brands.isEmpty {
                            Text(brands)
                                .font(NQText.captionS.font)
                                .foregroundStyle(NQTheme.inkMuted)
                        }
                    }
                    Spacer(minLength: 0)
                    if let score = result.nutritionScore {
                        NQChip("Score \(Int(score.rounded()))", icon: .star, tint: accent.accent)
                    }
                }
                if let n = result.nutrition {
                    HStack(alignment: .firstTextBaseline, spacing: NQTheme.spaceS) {
                        Text(n.calories.map { "\(Int($0.rounded())) kcal" } ?? "— kcal")
                            .font(NQText.headingL.font)
                            .foregroundStyle(accent.accentDark)
                        Text("per 100 g")
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                    }
                    HStack(spacing: NQTheme.spaceM) {
                        nutrientPill("Protein", value: n.proteinG, unit: "g", tint: NQTheme.protein)
                        nutrientPill("Carbs", value: n.carbsG, unit: "g", tint: NQTheme.carbs)
                        nutrientPill("Fat", value: n.fatG, unit: "g", tint: NQTheme.fat)
                    }
                    HStack(spacing: NQTheme.spaceM) {
                        nutrientPill("Fiber", value: n.fiberG, unit: "g", tint: NQTheme.fibre)
                        nutrientPill("Sugar", value: n.sugarG, unit: "g", tint: NQTheme.warning)
                        nutrientPill("Sodium", value: n.sodiumMg, unit: "mg", tint: NQTheme.info)
                    }
                } else {
                    Text("No nutrition facts on file for this product.")
                        .font(NQText.captionS.font)
                        .foregroundStyle(NQTheme.inkMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(productAccessibilityLabel(result))
    }

    private func productAccessibilityLabel(_ result: ScanResultDTO) -> String {
        guard let calories = result.nutrition?.calories else {
            return "\(result.foodName): no nutrition facts on file"
        }
        return "\(result.foodName): \(Int(calories.rounded())) kilocalories per 100 grams"
    }

    /// The barcode path — server-authoritative: `POST /scan` fetches the
    /// nutrition from Open Food Facts itself, scores it, and mints a ★1
    /// catalog monster the first time this player ever scans the barcode.
    /// A best-effort local OFF lookup enriches the day log (food group,
    /// micro score) but never decides anything.
    private func handleScan(_ payload: String, _ symbology: String?) {
        isScanning = false
        NQJuice.tap()
        // UPC-E expands to UPC-A: that is the code product databases key on.
        let code = BarcodeUtils.lookupCode(for: payload, symbology: symbology)
        // Mirror the server's rule so a non-product code fails with a useful
        // message instead of a round trip and a 400.
        guard (6...20).contains(code.count), code.allSatisfy(\.isNumber) else {
            errorMessage = "That doesn't look like a product barcode. Try the EAN/UPC code on the package."
            return
        }
        scanResult = nil
        summonedCharacter = nil
        isLookingUp = true
        Task {
            do {
                let result = try await APIClient.shared.scanBarcode(code)
                let product = try? await service.lookup(barcode: code)
                isLookingUp = false
                scanResult = result
                if let character = gameState.registerScanResult(result, product: product) {
                    summonedCharacter = character
                    playSummonSequence()
                }
            } catch APIError.badStatus(let code, _) where code == 400 {
                isLookingUp = false
                errorMessage = "That barcode isn't a product code. Try the EAN/UPC on the package."
            } catch APIError.badStatus(let code, _) where code == 404 {
                isLookingUp = false
                errorMessage = "Product not found in Open Food Facts. Try another barcode."
            } catch APIError.badStatus(let code, let body) where code == 422 {
                isLookingUp = false
                // The scan worked; the community database row didn't. Say so.
                let reasons = Self.plausibilityReasons(body)
                let detail = reasons.isEmpty ? "" : " (\(reasons.joined(separator: "; ")))"
                errorMessage = "Open Food Facts has broken nutrition data for this product\(detail). Nothing was logged or summoned; try another barcode on the pack."
            } catch {
                isLookingUp = false
                errorMessage = "Scan failed: \(error.localizedDescription). Check your connection and try again."
            }
        }
    }

    /// The server's 422 carries the exact rule the Open Food Facts entry
    /// broke; showing it makes "sanity checks" mean something to the user.
    private static func plausibilityReasons(_ body: String?) -> [String] {
        guard let data = body?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let reasons = error["reasons"] as? [String] else { return [] }
        return reasons
    }

    private func handleUnavailable(_ message: String) {
        isScanning = false
        errorMessage = message
    }

    /// Ask for the camera up front. VisionKit's `isAvailable` folds a not-yet-
    /// asked permission in with a refused one, so the system prompt has to be
    /// driven explicitly or a first-time user is told to go to Settings.
    private func startScanning() {
        errorMessage = nil
        cameraDenied = false
        guard ScannerView.isSupported else {
            errorMessage = "This device can't scan barcodes."
            return
        }
        Task {
            switch await CameraPermission.request() {
            case .granted:
                isScanning = true
            case .denied:
                cameraDenied = true
                errorMessage = "Camera permission is needed to scan. Enable it in Settings and try again."
            case .restricted:
                errorMessage = "Camera access is restricted on this device."
            }
        }
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
                // The server rejects payloads over ~9MB base64; a full-res
                // camera shot blows past that, so shrink the long edge first.
                let scaled = Self.downscale(image, maxDimension: 1280)
                guard let jpeg = scaled.jpegData(compressionQuality: 0.55) else {
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

    /// Long-edge clamp for upload; keeps aspect ratio, no-op when already small.
    private static func downscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
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

    private func nutrientPill(_ label: String, value: Double?, unit: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(NQText.micro.font.weight(.bold)).foregroundStyle(tint)
            Text(value.map { "\(Int($0.rounded()))\(unit)" } ?? "—")
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.ink)
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
                NQChip(String(repeating: "★", count: max(1, character.starLevel)), tint: NQTheme.gold, filled: true)
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
