import SwiftUI
import NutriQuestUI

/// Loot crate opening screen — full capsule mechanic.
///
/// Flow:
///   1. Catalog: crate cards with odds, key balance, pull history, pity counter
///   2. Open: capsule drops, shakes, cracks, reveals character
///   3. Multi-open: 1/5/10 batch with stacked reveals
///   4. Fairness: server seed hash shown, verify link
///   5. Key store: earn keys (placeholder for gameplay integration)
struct CrateOpeningView: View {
    @ObservedObject var gameState: GameState
    /// .sheet presents a fresh environment -- custom @Environment keys like
    /// nqAccent don't inherit from the presenting view automatically, so the
    /// caller passes the accent explicitly rather than the reveal always
    /// rendering with the neutral default.
    var accentContext: NQAccentContext = .neutral
    /// When true, this is the Casino tab's Shop pane — no Close chrome, no
    /// nested NavigationStack (the tab already has one).
    var embedded: Bool = false
    var onDismiss: () -> Void

    @Environment(\.nqAccent) private var accent
    @Environment(\.dismiss) private var dismiss
    @State private var crates: [CrateSummaryDTO] = []
    @State private var loadingCrates = true
    @State private var opening = false
    @State private var revealedDrops: [CrateOpenResponse] = []
    @State private var currentDropIndex = 0
    @State private var capsuleStage: NQCapsuleStage = .hidden
    @State private var chargeProgress: Double = 0
    @State private var chargeContinuation: CheckedContinuation<Void, Never>?
    @State private var holdTask: Task<Void, Never>?
    @State private var confettiTrigger = 0
    @State private var batchCount = 1
    @State private var showFairness = false
    @State private var tab: CrateTab = .catalog
    @State private var promoCode = ""
    @State private var promoRedeeming = false
    @State private var promoResult: String?
    @State private var openingCrateId = "starter-crate"
    @State private var pendingSale: InventoryItemDTO?

    enum CrateTab: String, CaseIterable {
        case catalog = "Crates"
        case sell = "Sell"
        case history = "History"
        case keys = "Keys"
    }

    var body: some View {
        Group {
            if embedded {
                shopBody
            } else {
                NavigationStack {
                    shopBody
                        .navigationTitle("Summon Crates")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Close") {
                                    onDismiss()
                                    dismiss()
                                }
                            }
                            ToolbarItem(placement: .navigationBarTrailing) {
                                fairnessButton
                            }
                        }
                }
            }
        }
        .nqAccentContext(accentContext)
        .task {
            crates = await gameState.refreshCrates()
            await gameState.refreshInventory(limit: 200)
            await gameState.refreshCoins()
            loadingCrates = false
        }
        .sheet(isPresented: $showFairness) {
            FairnessSheet(gameState: gameState)
        }
        .alert("Sell this monster?", isPresented: Binding(
            get: { pendingSale != nil },
            set: { if !$0 { pendingSale = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingSale = nil }
            Button("Sell", role: .destructive) {
                if let item = pendingSale {
                    pendingSale = nil
                    Task { await confirmSale(item) }
                }
            }
        } message: {
            if let item = pendingSale {
                Text("\(item.character.name) leaves the collection. You get \(item.value) coins — full net worth.")
            }
        }
    }

    private var fairnessButton: some View {
        Button {
            showFairness = true
        } label: {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 14, weight: .semibold))
        }
        .accessibilityLabel("Fairness verifier")
    }

    private var shopBody: some View {
        ZStack {
            NQTheme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                tabPicker

                switch tab {
                case .catalog:
                    catalogTab
                case .sell:
                    sellTab
                case .history:
                    historyTab
                case .keys:
                    keysTab
                }
            }

            if opening || !revealedDrops.isEmpty {
                capsuleOverlay
                    .transition(NQTransition.summon)
            }
        }
        .animation(NQMotion.springy, value: opening)
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        HStack(spacing: NQTheme.spaceS) {
            ForEach(CrateTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(NQMotion.quick) {
                        self.tab = tab
                    }
                    NQSound.play(.toggle)
                    NQHaptic.light()
                } label: {
                    Text(tab.rawValue)
                        .font(NQText.caption.font.weight(.semibold))
                        .foregroundStyle(self.tab == tab ? accent.accent : NQTheme.inkMuted)
                        .padding(.horizontal, NQTheme.spaceM)
                        .padding(.vertical, NQTheme.spaceS)
                        .background(
                            self.tab == tab ? accent.accent.opacity(0.12) : Color.clear
                        )
                        .clipShape(Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NQTheme.spaceS)
        .background(NQTheme.surface)
        .overlay(alignment: .trailing) {
            if embedded {
                fairnessButton
                    .padding(.trailing, NQTheme.spaceS)
            }
        }
    }

    // MARK: - Catalog tab

    private var catalogTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                keyBalance

                // Welcome-back gift: armed after >3 days away, one free pull.
                if gameState.comebackPending {
                    comebackCard
                }

                if loadingCrates {
                    HStack(spacing: NQTheme.spaceM) {
                        NQSkeleton(width: 140, height: 180, cornerRadius: NQTheme.radiusL)
                        NQSkeleton(width: 140, height: 180, cornerRadius: NQTheme.radiusL)
                    }
                    .frame(maxWidth: .infinity)
                } else if crates.isEmpty {
                    emptyCratesState
                } else {
                    ForEach(crates, id: \.id) { crate in
                        crateCard(crate)
                    }
                }

                if let error = gameState.backendError {
                    NQBanner.error(error, onDismiss: { gameState.backendError = nil })
                }
            }
            .padding(NQTheme.spaceL)
        }
    }

    private var keyBalance: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                NQSectionHeader("Your keys")
                if let inventory = gameState.crateInventory {
                    Text("\(inventory.count) pulls · \(inventory.totalValue) total value")
                        .font(NQText.micro.font)
                        .foregroundStyle(NQTheme.inkFaint)
                }
            }
            Spacer()
            if let keys = gameState.keysRemaining {
                HStack(spacing: NQTheme.spaceXS) {
                    NQAssetImage("key")
                        .frame(width: 22, height: 22)
                    AnimatedKeyCount(keys: keys)
                }
                .foregroundStyle(NQTheme.gold)
                .accessibilityLabel("\(keys) keys available")
            } else {
                NQSkeleton(width: 40, height: 18)
            }
        }
    }

    private func crateCard(_ crate: CrateSummaryDTO) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            NQAssetImage(GameArt.crateClosed(crate.id))
                .frame(height: 92)
                .frame(maxWidth: .infinity)
            HStack {
                Text(crate.name)
                    .font(NQText.headingL.font)
                    .foregroundStyle(NQTheme.ink)
                Spacer()
                NQChip("\(crate.keyCost) key\(crate.keyCost == 1 ? "" : "s")", icon: .sparkle, filled: true)
            }
            Text(crate.description)
                .font(NQText.caption.font)
                .foregroundStyle(NQTheme.inkMuted)

            // Pity meters — visible proximity to a guaranteed pull is the
            // "one more open" lever. Shown only while a guarantee is pending.
            if let pity = crate.pity ?? gameState.pity {
                pityRow(pity)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NQTheme.spaceXS) {
                    ForEach(crate.odds, id: \.rarity) { odd in
                        NQChip(odd.label, tint: Color(hex: oddColorHex(odd)))
                            .fixedSize()
                    }
                }
            }

            // Multi-open selector
            if canAfford(crate, count: 1) {
                HStack(spacing: NQTheme.spaceS) {
                    ForEach([1, 5, 10], id: \.self) { count in
                        let affordable = canAfford(crate, count: count)
                        Button {
                            batchCount = count
                            NQHaptic.light()
                        } label: {
                            Text("×\(count)")
                                .font(NQText.caption.font.weight(.bold))
                                .foregroundStyle(batchCount == count ? .white : (affordable ? NQTheme.ink : NQTheme.inkFaint))
                                .frame(width: 36, height: 28)
                                .background(batchCount == count ? accent.accent : NQTheme.hairline)
                                .clipShape(Capsule())
                        }
                        .disabled(!affordable)
                    }
                    Spacer()
                }
            }

            Button {
                openCrate(crate)
            } label: {
                HStack {
                    if opening {
                        ProgressView().tint(.white)
                    } else {
                        NQIcon.sparkle.view.frame(width: 15, height: 15)
                    }
                    Text(opening ? "Opening…" : "Open ×\(batchCount)")
                        .font(NQText.heading.font)
                }
                .frame(maxWidth: .infinity)
                .nqPadding(.button)
                .background(canAfford(crate, count: batchCount) ? accent.accent : NQTheme.lockedFill)
                .foregroundStyle(canAfford(crate, count: batchCount) ? accent.accent.readableTextColor() : NQTheme.inkMuted)
                .clipShape(Capsule())
            }
            .buttonStyle(NQPressableStyle())
            .disabled(!canAfford(crate, count: batchCount) || opening)
            .accessibilityLabel("Open \(crate.name) \(batchCount) times")
        }
        .nqPadding(.card)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL), elevation: .card)
    }

    /// "Epic+ in N" / "Legendary+ in M" — thin progress bars toward each
    /// guarantee. Hidden once either counter is fresh.
    private func pityRow(_ pity: PityDTO) -> some View {
        HStack(spacing: NQTheme.spaceM) {
            pityMeter(label: "Epic+", remaining: pity.epicIn, total: 15, tint: NQRarity.epic.outline)
            pityMeter(label: "Legendary+", remaining: pity.legendaryIn, total: 40, tint: NQRarity.legendary.outline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Epic or better guaranteed in \(pity.epicIn) opens. Legendary or better in \(pity.legendaryIn).")
    }

    private func pityMeter(label: String, remaining: Int, total: Int, tint: Color) -> some View {
        let progress = Double(total - remaining) / Double(total)
        return HStack(spacing: NQTheme.spaceS) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            Text(remaining <= 1 ? "\(label) next!" : "\(label) in \(remaining)")
                .font(NQText.micro.font.weight(.heavy))
                .foregroundStyle(remaining <= 3 ? tint : NQTheme.inkMuted)
        }
    }

    private func canAfford(_ crate: CrateSummaryDTO, count: Int) -> Bool {
        (gameState.keysRemaining ?? 0) >= crate.keyCost * count
    }

    private func oddColorHex(_ odd: CrateOddsDTO) -> String {
        odd.colorHex.hasPrefix("#") ? odd.colorHex : "#\(odd.colorHex)"
    }

    /// The comeback crate — free pull, gold-trimmed, opens through the same
    /// capsule sequence as a paid open.
    private var comebackCard: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            HStack {
                NQIcon.crown.view
                    .frame(width: 22, height: 22)
                    .foregroundStyle(NQTheme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome back!")
                        .font(NQText.headingL.font.weight(.heavy))
                        .foregroundStyle(NQTheme.ink)
                    Text(gameState.comebackDaysAway > 0
                         ? "You were away \(gameState.comebackDaysAway) days — this one's on us."
                         : "This one's on us.")
                        .font(NQText.caption.font)
                        .foregroundStyle(NQTheme.inkMuted)
                }
                Spacer()
            }
            Button {
                openComebackCrate()
            } label: {
                HStack {
                    if opening {
                        ProgressView().tint(.white)
                    } else {
                        NQIcon.sparkle.view.frame(width: 15, height: 15)
                    }
                    Text("Open free crate")
                        .font(NQText.heading.font)
                }
                .frame(maxWidth: .infinity)
                .nqPadding(.button)
                .background(NQTheme.gold)
                .foregroundStyle(NQTheme.ink)
                .clipShape(Capsule())
            }
            .buttonStyle(NQPressableStyle())
            .disabled(opening)
            .accessibilityLabel("Open your free welcome-back crate")
        }
        .nqPadding(.card)
        .background(NQTheme.gold.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
        .overlay {
            RoundedRectangle(cornerRadius: NQTheme.radiusL)
                .strokeBorder(NQTheme.gold.opacity(0.5), lineWidth: 2)
        }
    }

    private func openComebackCrate() {
        opening = true
        revealedDrops = []
        currentDropIndex = 0
        capsuleStage = .hidden

        Task {
            guard let drop = await gameState.claimComeback() else {
                opening = false
                return
            }
            revealedDrops = [drop]
            await playCapsuleSequence(for: drop)
        }
    }

    private var emptyCratesState: some View {
        VStack(spacing: NQTheme.spaceM) {
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundStyle(NQTheme.inkFaint)
            Text("No crates available")
                .font(NQText.heading.font)
                .foregroundStyle(NQTheme.inkMuted)
            Text("Crates appear here when the backend is reachable.")
                .font(NQText.caption.font)
                .foregroundStyle(NQTheme.inkFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(NQTheme.spaceXL)
    }

    // MARK: - Sell tab

    private var sellTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        NQSectionHeader("Coin purse")
                        Text("Sell a pulled monster for its full net worth.")
                            .font(NQText.micro.font)
                            .foregroundStyle(NQTheme.inkFaint)
                    }
                    Spacer()
                    HStack(spacing: NQTheme.spaceXS) {
                        NQIcon.sparkle.view.frame(width: 18, height: 18)
                        Text("\(gameState.coinBalance)")
                            .font(NQText.headingL.font)
                    }
                    .foregroundStyle(NQTheme.gold)
                    .accessibilityLabel("\(gameState.coinBalance) coins")
                }

                if let items = gameState.crateInventory?.items, !items.isEmpty {
                    ForEach(items) { item in
                        sellRow(item)
                    }
                } else {
                    NQEmptyState(message: "No pulled monsters to sell. Open a crate first.")
                        .padding(.top, NQTheme.spaceXL)
                }
            }
            .padding(NQTheme.spaceL)
        }
    }

    private func sellRow(_ item: InventoryItemDTO) -> some View {
        let character = Character(
            id: "crate-\(item.character.id)",
            name: item.character.name,
            colorHex: item.character.colorHex,
            rarity: Rarity(rawValue: item.character.rarity) ?? .common,
            statType: StatType(rawValue: item.character.statType) ?? .fiber,
            isShiny: item.shiny
        )
        return HStack(spacing: NQTheme.spaceM) {
            CharacterArtwork(character: character)
                .frame(width: 52, height: 68)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.character.name)
                    .font(NQText.heading.font)
                    .foregroundStyle(NQTheme.ink)
                    .lineLimit(1)
                Text("\(item.character.rarity.capitalized) · \(item.value) coins")
                    .font(NQText.caption.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
            Spacer()
            if item.isStaked {
                NQChip("Staked", tint: NQTheme.warning)
            } else {
                Button {
                    NQSound.play(.tapAlt)
                    pendingSale = item
                } label: {
                    Text("Sell")
                        .font(NQText.caption.font.weight(.heavy))
                        .foregroundStyle(NQTheme.background)
                        .nqPadding(.badge)
                        .background(NQTheme.gold)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sell \(item.character.name) for \(item.value) coins")
            }
        }
        .nqPadding(.card)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL), elevation: .card)
    }

    @MainActor
    private func confirmSale(_ item: InventoryItemDTO) async {
        if let coins = await gameState.sellMonster(dropID: item.id) {
            NQSound.play(.coins)
            NQJuice.success()
            _ = coins
        }
    }

    // MARK: - History tab

    private var historyTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                if let inventory = gameState.crateInventory {
                    // Rarity distribution
                    rarityDistribution(inventory.items)

                    // Recent pulls
                    NQSectionHeader("Recent pulls (\(inventory.items.count))")
                    if inventory.items.isEmpty {
                        emptyHistoryState
                    } else {
                        ForEach(inventory.items.prefix(20)) { item in
                            pullRow(item)
                        }
                    }
                } else {
                    NQContentState(.loading("Loading..."))
                        .frame(height: 200)
                }
            }
            .padding(NQTheme.spaceL)
        }
        .task {
            await gameState.refreshInventory(limit: 100)
        }
    }

    private func rarityDistribution(_ items: [InventoryItemDTO]) -> some View {
        let counts = Dictionary(grouping: items, by: { $0.character.rarity })
            .mapValues { $0.count }
        let sorted = NQRarity.allCases.sorted { (counts[$0.rawValue] ?? 0) > (counts[$1.rawValue] ?? 0) }

        return VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            NQSectionHeader("Collection distribution")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NQTheme.spaceS) {
                    ForEach(sorted, id: \.self) { rarity in
                        let count = counts[rarity.rawValue] ?? 0
                        VStack(spacing: 4) {
                            Text("\(count)")
                                .font(NQText.headingL.font)
                                .foregroundStyle(rarity.outline)
                            Text(rarity.displayName)
                                .font(NQText.micro.font)
                                .foregroundStyle(NQTheme.inkMuted)
                        }
                        .frame(width: 72)
                        .padding(.vertical, NQTheme.spaceS)
                        .background(rarity.badgeBackground)
                        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusS))
                    }
                }
            }
        }
    }

    private func pullRow(_ item: InventoryItemDTO) -> some View {
        HStack(spacing: NQTheme.spaceM) {
            // Rarity dot
            Circle()
                .fill(rarityColor(item.character.rarity))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.character.name)
                    .font(NQText.body.font.weight(.semibold))
                    .foregroundStyle(NQTheme.ink)
                HStack(spacing: NQTheme.spaceXS) {
                    Text(item.character.rarity.capitalized)
                        .font(NQText.micro.font)
                        .foregroundStyle(NQTheme.inkMuted)
                    if item.shiny {
                        NQChip("Shiny", icon: .sparkle, tint: NQTheme.gold, filled: true)
                    }
                    Text("· \(item.powerLabel)")
                        .font(NQText.micro.font)
                        .foregroundStyle(NQTheme.inkFaint)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(item.value)")
                    .font(NQText.heading.font)
                    .foregroundStyle(NQTheme.gold)
                Text(item.openedAt.slice(0, 10))
                    .font(NQText.micro.font)
                    .foregroundStyle(NQTheme.inkFaint)
            }
        }
        .nqPadding(.card)
        .background(NQTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusM))
    }

    private var emptyHistoryState: some View {
        VStack(spacing: NQTheme.spaceM) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(NQTheme.inkFaint)
            Text("No pulls yet")
                .font(NQText.heading.font)
                .foregroundStyle(NQTheme.inkMuted)
            Text("Open a crate to start your collection.")
                .font(NQText.caption.font)
                .foregroundStyle(NQTheme.inkFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(NQTheme.spaceXL)
    }

    // MARK: - Keys tab

    private var keysTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                // Current balance
                VStack(spacing: NQTheme.spaceS) {
                    NQSectionHeader("Key balance")
                    HStack {
                        NQIcon.sparkle.view.frame(width: 28, height: 28)
                            .foregroundStyle(NQTheme.gold)
                        if let keys = gameState.keysRemaining {
                            Text("\(keys)")
                                .font(NQText.displayL.font)
                                .foregroundStyle(NQTheme.ink)
                        } else {
                            NQSkeleton(width: 60, height: 40)
                        }
                        Spacer()
                    }
                }
                .nqPadding(.card)
                .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL), fill: NQTheme.surface, elevation: .card)

                // Earn keys
                NQSectionHeader("Earn keys")
                keySourceCard(
                    icon: "barcode.viewfinder",
                    title: "Scan a food",
                    desc: "Each daily scan grants 1 key",
                    keys: "+1"
                )
                keySourceCard(
                    icon: "figure.walk",
                    title: "Close activity rings",
                    desc: "All 3 rings → +2 keys (daily)",
                    keys: "+2"
                )
                keySourceCard(
                    icon: "trophy.fill",
                    title: "Win a battle",
                    desc: "Each PvP win grants +3 keys",
                    keys: "+3"
                )
                keySourceCard(
                    icon: "flame.fill",
                    title: "7-day streak",
                    desc: "Bonus +5 keys on day 7",
                    keys: "+5"
                )

                // Promo code
                NQSectionHeader("Promo code")
                promoCodeSection

                Text("Keys are granted by gameplay actions.")
                    .font(NQText.micro.font)
                    .foregroundStyle(NQTheme.inkFaint)
            }
            .padding(NQTheme.spaceL)
        }
    }

    private func keySourceCard(icon: String, title: String, desc: String, keys: String) -> some View {
        HStack(spacing: NQTheme.spaceM) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(accent.accent)
                .frame(width: 40, height: 40)
                .background(accent.accent.opacity(0.1))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NQText.body.font.weight(.semibold))
                    .foregroundStyle(NQTheme.ink)
                Text(desc)
                    .font(NQText.micro.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }

            Spacer()

            NQChip(keys, icon: .sparkle, tint: NQTheme.gold, filled: true)
        }
        .nqPadding(.card)
        .background(NQTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusM))
    }

    // MARK: - Promo code

    private var promoCodeSection: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            HStack(spacing: NQTheme.spaceS) {
                TextField("Enter promo code", text: $promoCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .padding(NQTheme.spaceS)
                    .background(NQTheme.surface.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusM))

                NQButton("Redeem", icon: .sparkle, style: .primary) {
                    Task {
                        await redeemPromo()
                    }
                }
                .disabled(promoRedeeming || promoCode.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let message = promoResult {
                Text(message)
                    .font(NQText.caption.font)
                    .foregroundStyle(message.hasPrefix("+") ? NQTheme.success : Color.red)
                    .transition(.opacity)
            }
        }
        .nqPadding(.card)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL), fill: NQTheme.surface, elevation: .card)
    }

    private func redeemPromo() async {
        let code = promoCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return }
        promoRedeeming = true
        promoResult = nil

        if let response = await gameState.redeemPromo(code: code) {
            if let drop = response.result.drop {
                promoResult = "+1 \(drop.character.name) from a free crate!"
                revealedDrops = [drop]
                currentDropIndex = 0
                await playCapsuleSequence(for: drop)
            } else if response.result.reward.hasPrefix("keys:") {
                promoResult = "+\(response.result.keys) keys added!"
                NQJuice.keys()
            } else {
                promoResult = "Redeemed \(response.result.reward)"
            }
        } else if let error = gameState.backendError {
            promoResult = error
        }

        promoRedeeming = false
        promoCode = ""
        await gameState.refreshInventory()
    }

    // MARK: - Capsule overlay (open sequence)

    private var capsuleOverlay: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.6).ignoresSafeArea()

            // Confetti for high-rarity
            NQConfetti(trigger: confettiTrigger)
                .ignoresSafeArea()

            VStack(spacing: NQTheme.spaceL) {
                Spacer()

                if currentDropIndex < revealedDrops.count {
                    let drop = revealedDrops[currentDropIndex]
                    let rarity = nqRarity(from: drop.character.rarity)

                    NQCapsule(
                        stage: capsuleStage,
                        rarity: rarity,
                        chargeProgress: chargeProgress,
                        closedArtwork: caseArtwork(rarity, opened: false),
                        openedArtwork: caseArtwork(rarity, opened: true)
                    ) {
                        NQAssetImage(GameArt.sprite(id: drop.character.id))
                        .frame(width: 170, height: 220)
                        .nqBreathingGlow(color: rarityColor(drop.character.rarity))
                    }
                    .frame(height: 320)
                    .contentShape(Rectangle())
                    .gesture(chargeHoldGesture)
                    .onTapGesture {
                        // Accessibility escape: a plain tap completes the charge.
                        if capsuleStage == .charging { chargeProgress = 1 }
                    }
                    .onChange(of: chargeProgress) { p in
                        // Any path to a full charge (hold loop or tap) resumes
                        // the suspended reveal sequence exactly once.
                        if p >= 1 && capsuleStage == .charging, let cont = chargeContinuation {
                            chargeContinuation = nil
                            NQJuice.reveal()
                            cont.resume()
                        }
                    }

                    // Charge hint (only while holding is meaningful)
                    if capsuleStage == .charging {
                        Text(chargeProgress > 0 ? "Keep holding…" : "Hold the capsule to summon")
                            .font(NQText.body.font.weight(.bold))
                            .foregroundStyle(.white.opacity(0.9))
                            .transition(.opacity)
                    }

                    // Drop info (visible at .open)
                    if capsuleStage == .open {
                        dropInfo(drop, index: currentDropIndex, total: revealedDrops.count)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }

                Spacer()

                // Controls
                if capsuleStage == .open {
                    capsuleControls
                        .transition(.opacity)
                }
            }
            .padding(NQTheme.spaceXL)
        }
    }

    private func dropInfo(_ drop: CrateOpenResponse, index: Int, total: Int) -> some View {
        VStack(spacing: NQTheme.spaceS) {
            if total > 1 {
                Text("Pull \(index + 1) of \(total)")
                    .font(NQText.micro.font)
                    .foregroundStyle(.white.opacity(0.7))
            }

            Text(drop.character.name)
                .font(NQText.displayL.font)
                .foregroundStyle(.white)

            NQChip(
                drop.character.rarityLabel ?? drop.character.rarity.capitalized,
                tint: rarityColor(drop.character.rarity),
                filled: true
            )

            if let flavor = drop.character.flavor, !flavor.isEmpty {
                Text(flavor)
                    .font(NQText.bodyL.font)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, NQTheme.spaceL)
            }

            HStack(spacing: NQTheme.spaceL) {
                statPill("Power", String(format: "%.0f", drop.power), drop.powerLabel)
                if drop.shiny {
                    HStack(spacing: 4) {
                        NQAssetImage("star-badge")
                            .frame(width: 22, height: 22)
                        NQChip("Shiny", icon: .sparkle, tint: NQTheme.gold, filled: true)
                    }
                }
                statPill("Value", "\(drop.value)", "points")
            }
        }
    }

    private var capsuleControls: some View {
        HStack(spacing: NQTheme.spaceM) {
            if currentDropIndex < revealedDrops.count - 1 {
                NQButton("Next pull", icon: .sparkle, style: .primary, fullWidth: false) {
                    advanceToNextDrop()
                }
            } else {
                NQButton("Open another", icon: .sparkle, style: .primary, fullWidth: false) {
                    closeCapsuleOverlay()
                }
            }

            Button("Skip") {
                closeCapsuleOverlay()
            }
            .font(NQText.body.font)
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    /// Reward numbers roll up instead of appearing — the count IS the moment.
    private func statPill(_ label: String, _ value: String, _ tier: String) -> some View {
        VStack(spacing: 2) {
            if let numeric = Int(value) {
                NQCountUpText(value: numeric, font: NQText.headingL.font, color: .white)
            } else {
                Text(value)
                    .font(NQText.headingL.font)
                    .foregroundStyle(.white)
            }
            Text("\(label) · \(tier)")
                .font(NQText.micro.font)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Open sequence

    private func openCrate(_ crate: CrateSummaryDTO) {
        opening = true
        openingCrateId = crate.id
        revealedDrops = []
        currentDropIndex = 0
        capsuleStage = .hidden

        Task {
            var drops: [CrateOpenResponse] = []
            for _ in 0..<batchCount {
                if let drop = await gameState.openCrate(crateID: crate.id) {
                    drops.append(drop)
                    gameState.addCrateCharacter(drop: drop)
                }
            }

            guard !drops.isEmpty else {
                opening = false
                return
            }

            revealedDrops = drops
            await playCapsuleSequence(for: drops[0])
        }
    }

    @MainActor
    private func playCapsuleSequence(for drop: CrateOpenResponse) async {
        // Suspense scales with rarity: a legendary should feel earned.
        let tier = suspenseTier(for: drop.character.rarity)

        // Drop in
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            capsuleStage = .dropping
        }
        NQSound.play(.crateCreak)
        try? await Task.sleep(nanoseconds: 600_000_000)

        // Hold-to-charge: the player builds the crack. Skipped under
        // Reduce Motion — the capsule should never gate opening on a hold.
        if !UIAccessibility.isReduceMotionEnabled {
            chargeProgress = 0
            capsuleStage = .charging
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                chargeContinuation = cont
            }
            chargeContinuation = nil
        }

        // Shake — longer, with extra haptic beats for high tiers.
        withAnimation(NQMotion.quick) {
            capsuleStage = .shaking
        }
        NQHaptic.light()
        NQSound.play(.crateRoll)
        NQSound.startLoop(.crateRumble)
        try? await Task.sleep(nanoseconds: suspenseDuration(tier: tier))
        if tier >= 2 { NQHaptic.medium() }
        try? await Task.sleep(nanoseconds: tier >= 2 ? 500_000_000 : 200_000_000)
        if tier >= 3 { NQHaptic.warning() }
        try? await Task.sleep(nanoseconds: tier >= 3 ? 400_000_000 : 100_000_000)
        NQSound.stopLoop(.crateRumble)

        // Crack
        withAnimation(.easeOut(duration: 0.2)) {
            capsuleStage = .cracking
        }
        NQJuice.unlock()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Open
        withAnimation(.spring(response: 0.55, dampingFraction: 0.65)) {
            capsuleStage = .open
        }
        NQSound.play(.crateOpen)
        NQSound.play(.crateReveal)
        if drop.character.rarity == "secret" {
            NQSound.play(.revealAlt)
        }
        NQJuice.success()

        // Confetti for high rarity
        if ["legendary", "mythic", "secret"].contains(drop.character.rarity) {
            confettiTrigger += 1
        }

        opening = false
    }

    // MARK: - Hold-to-charge

    /// Press-and-hold on the capsule: progress fills over `chargeDuration`,
    /// with haptic ticks that tighten as the charge builds. Releasing early
    /// drains the charge back to zero — the anticipation is the mechanic.
    private var chargeHoldGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in beginHold() }
            .onEnded { _ in endHold() }
    }

    /// Seconds to full charge — hotter pulls take longer to crack.
    private func chargeDuration(for rarity: String) -> Double {
        switch suspenseTier(for: rarity) {
        case 4: return 1.15
        case 3: return 0.95
        case 2: return 0.8
        default: return 0.65
        }
    }

    private func beginHold() {
        guard capsuleStage == .charging, holdTask == nil else { return }
        NQSound.play(.hover)
        let duration = chargeDuration(for: revealedDrops[currentDropIndex].character.rarity)
        var lastTick = chargeProgress
        holdTask = Task { @MainActor in
            var last = Date()
            while capsuleStage == .charging && chargeProgress < 1 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000)
                let now = Date()
                chargeProgress = min(1, chargeProgress + now.timeIntervalSince(last) / duration)
                last = now
                // Haptic ticks get denser as the ring fills.
                if chargeProgress - lastTick >= 0.12 {
                    lastTick = chargeProgress
                    NQSound.play(.hitLight)
                    if chargeProgress > 0.75 { NQHaptic.medium() } else { NQHaptic.light() }
                }
            }
            // The onChange watcher on chargeProgress owns resuming the reveal.
            holdTask = nil
        }
    }

    private func endHold() {
        holdTask?.cancel()
        holdTask = nil
        if capsuleStage == .charging && chargeProgress < 1 {
            chargeProgress = 0
            NQHaptic.light()
        }
    }

    /// 1 = common/uncommon, 2 = rare, 3 = epic, 4 = legendary+.
    private func suspenseTier(for rarity: String) -> Int {
        switch rarity.lowercased() {
        case "rare": return 2
        case "epic": return 3
        case "legendary", "mythic", "secret": return 4
        default: return 1
        }
    }

    private func suspenseDuration(tier: Int) -> UInt64 {
        switch tier {
        case 4: return 1_900_000_000
        case 3: return 1_400_000_000
        case 2: return 1_100_000_000
        default: return 800_000_000
        }
    }

    private func advanceToNextDrop() {
        let next = currentDropIndex + 1
        guard next < revealedDrops.count else {
            closeCapsuleOverlay()
            return
        }

        withAnimation(NQMotion.quick) {
            capsuleStage = .hidden
            currentDropIndex = next
        }

        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await playCapsuleSequence(for: revealedDrops[next])
        }
    }

    private func closeCapsuleOverlay() {
        withAnimation(NQMotion.quick) {
            capsuleStage = .hidden
            revealedDrops = []
            currentDropIndex = 0
            opening = false
        }
        Task { await gameState.refreshInventory() }
    }

    // MARK: - Helpers

    /// Themed crate art from `game-assets/`. Falls back to the pull's rarity chest.
    private func caseArtwork(_ rarity: NQRarity, opened: Bool) -> AnyView {
        let themed = opened
            ? GameArt.crateOpened(openingCrateId)
            : GameArt.crateClosed(openingCrateId)
        let name = NQAsset.uiImage(themed) == nil
            ? GameArt.rarityChest(closed: rarity, opened: opened)
            : themed
        return AnyView(
            NQAssetImage(name)
                .aspectRatio(contentMode: .fit)
        )
    }

    private func rarityColor(_ rarity: String) -> Color {
        NQRarity(rawValue: rarity.lowercased())?.outline ?? NQTheme.gold
    }

    private func nqRarity(from string: String) -> NQRarity {
        NQRarity(rawValue: string.lowercased()) ?? .common
    }
}

// MARK: - Animated key counter

private struct AnimatedKeyCount: View {
    let keys: Int
    @State private var displayKeys: Int
    @State private var bump = false

    init(keys: Int) {
        self.keys = keys
        _displayKeys = State(initialValue: keys)
    }

    var body: some View {
        Text("\(displayKeys)")
            .font(NQText.heading.font)
            .scaleEffect(bump ? 1.3 : 1.0)
            .onChange(of: keys) { newValue in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                    bump = true
                }
                withAnimation(.easeOut(duration: 0.4)) {
                    displayKeys = newValue
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        bump = false
                    }
                }
            }
    }
}

// MARK: - Fairness sheet

private struct FairnessSheet: View {
    @ObservedObject var gameState: GameState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                    fairnessSection
                    verifySection
                    retiredSection
                    rotateSection
                }
                .padding(NQTheme.spaceL)
            }
            .navigationTitle("Fairness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await gameState.refreshFairness()
            }
        }
    }

    private var fairnessSection: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            NQSectionHeader("Commit-reveal")
            Text("The server publishes a hash of its seed before you open. After rotating, the seed is revealed so you can verify every roll was fair.")
                .font(NQText.body.font)
                .foregroundStyle(NQTheme.inkMuted)
        }
    }

    private var verifySection: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            NQSectionHeader("Current seed")
            if let fairness = gameState.fairness {
                infoRow("Server seed hash", fairness.current.serverSeedHash)
                infoRow("Client seed", fairness.current.clientSeed)
                infoRow("Nonce", "\(fairness.current.nonce)")
            } else {
                NQContentState(.loading("Loading..."))
                    .frame(height: 100)
            }
        }
        .nqPadding(.card)
        .background(NQTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
    }

    private var retiredSection: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            NQSectionHeader("Retired seeds (revealed)")
            if let fairness = gameState.fairness {
                if fairness.retired.isEmpty {
                    Text("No retired seeds yet. Rotate to reveal the current one.")
                        .font(NQText.caption.font)
                        .foregroundStyle(NQTheme.inkFaint)
                } else {
                    ForEach(fairness.retired, id: \.serverSeedHash) { seed in
                        VStack(alignment: .leading, spacing: 4) {
                            infoRow("Server seed", seed.serverSeed ?? "—")
                            infoRow("Hash", seed.serverSeedHash)
                            infoRow("Nonce", "\(seed.nonce)")
                            if let retiredAt = seed.retiredAt {
                                infoRow("Retired", retiredAt.slice(0, 10))
                            }
                        }
                        .padding(.vertical, NQTheme.spaceS)
                        Divider()
                    }
                }
            } else {
                NQContentState(.loading("Loading..."))
                    .frame(height: 80)
            }
        }
        .nqPadding(.card)
        .background(NQTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusL))
    }

    private var rotateSection: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            NQSectionHeader("Rotate seed")
            Text("Rotating retires the current seed (revealing it) and commits a new one. Do this to verify past rolls.")
                .font(NQText.caption.font)
                .foregroundStyle(NQTheme.inkMuted)
            NQButton("Rotate seed", icon: .sparkle, style: .secondary) {
                Task { await gameState.rotateSeed() }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(NQText.caption.font)
                .foregroundStyle(NQTheme.inkMuted)
            Spacer()
            Text(value)
                .font(NQText.micro.font.weight(.medium))
                .foregroundStyle(NQTheme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Helpers

private func hexToUInt32(_ hex: String) -> UInt32 {
    let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    return UInt32(cleaned, radix: 16) ?? 0x9C978F
}

private extension String {
    func slice(_ start: Int, _ end: Int) -> String {
        guard count > start else { return self }
        let s = index(startIndex, offsetBy: start)
        let e = index(startIndex, offsetBy: min(end, count))
        return String(self[s..<e])
    }

    var capitalized: String {
        prefix(1).uppercased() + dropFirst().lowercased()
    }
}
