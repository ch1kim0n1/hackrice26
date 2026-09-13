import SwiftUI
import NutriQuestUI

/// The Casino tab.
///
/// Three panes behind one switch: the house games, the shop (crates +
/// selling monsters), and the Battle hub that used to own this tab.
struct CasinoHubView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.nqAccent) private var accent
    /// QA hook, matching RootTabView's `-uiTab`: `-uiSection casino|cases|battle`
    /// lands directly on that pane, so a screenshot can reach it without a tap.
    @State private var section: CasinoSection = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiSection"), args.count > i + 1 else { return .casino }
        return CasinoSection(rawValue: args[i + 1]) ?? .casino
    }()
    /// QA hook, matching RootTabView's `-uiTab`: `-uiGame cauldron`,
    /// `-uiGame mines` or `-uiGame shop` opens that screen straight away, so a
    /// screenshot can reach it without a tap.
    @State private var showShop = Self.launchGame == "shop"
    @State private var openCauldron = Self.launchGame == "cauldron"
    @State private var openMines = Self.launchGame?.hasPrefix("mines") == true
    @State private var openPlinko = Self.launchGame?.hasPrefix("plinko") == true
    @State private var openPortalWheel = Self.launchGame?.hasPrefix("wheel") == true

    private static var launchGame: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiGame"), args.count > i + 1 else { return nil }
        return args[i + 1]
    }
    @Namespace private var switcher

    /// The three panes of this tab: the house games, the player's granted
    /// Cases (sell/history/promo live there too), and the battle modes.
    enum CasinoSection: String, CaseIterable, Identifiable {
        case casino
        case cases
        case battle

        var id: String { rawValue }

        var title: String {
            switch self {
            case .casino: return "Casino"
            case .cases: return "Cases"
            case .battle: return "Battle"
            }
        }

        var icon: NQIcon {
            switch self {
            case .casino: return .cauldron
            case .cases: return .crown
            case .battle: return .battle
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            shopButton
                .padding(.horizontal, NQTheme.spaceL)
                .padding(.top, NQTheme.spaceS)

            sectionSwitch
                .padding(.horizontal, NQTheme.spaceL)
                .padding(.top, NQTheme.spaceM)
                .padding(.bottom, NQTheme.spaceS)

            switch section {
            case .casino:
                gamesFloor
            case .cases:
                CrateOpeningView(gameState: gameState, accentContext: accent, embedded: true, onDismiss: {})
            case .battle:
                BattleHubView(gameState: gameState)
            }
        }
        .nqSceneBackground(GameArt.scene("casino"))
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .nqTransparentNav()
        .toolbar {
            ToolbarItem(placement: .principal) {
                NQGameTitle(section.title)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NQCoinBalance(balance: gameState.coinBalance)
            }
        }
        .navigationDestination(isPresented: $showShop) {
            ShopView(gameState: gameState)
        }
        .navigationDestination(isPresented: $openCauldron) {
            CauldronCrashView(gameState: gameState)
        }
        .navigationDestination(isPresented: $openMines) {
            KitchenMinesView(gameState: gameState)
        }
        .navigationDestination(isPresented: $openPlinko) {
            PlinkoView(gameState: gameState)
        }
        .navigationDestination(isPresented: $openPortalWheel) {
            PortalWheelView(gameState: gameState)
        }
        .task {
            await gameState.loadCoinBalance()
            await gameState.loadCauldronConfig()
            await gameState.refreshCauldron()
            await gameState.loadMinesConfig()
            await gameState.refreshMines()
            await gameState.loadPlinkoConfig()
            await gameState.refreshPlinko()
            await gameState.loadPortalWheelConfig()
            await gameState.refreshPortalWheel()
        }
    }

    // MARK: - Section switch

    private var sectionSwitch: some View {
        HStack(spacing: 0) {
            ForEach(CasinoSection.allCases) { option in
                let isSelected = section == option
                Button {
                    NQSound.play(.tapAlt)
                    withAnimation(NQMotion.snappy) { section = option }
                } label: {
                    HStack(spacing: NQTheme.spaceXS) {
                        option.icon.view
                            .frame(width: 14, height: 14)
                        Text(option.title)
                            .font(NQText.caption.font.weight(.heavy))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(isSelected ? accent.accent.readableTextColor() : NQTheme.inkMuted)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: NQLayout.controlMinHeight)
                    .background {
                        if isSelected {
                            NQPanelShape(cut: NQTheme.radiusS)
                                .fill(
                                    LinearGradient(
                                        colors: [accent.accent, accent.accentDark],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .matchedGeometryEffect(id: "selected-section", in: switcher)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(NQTheme.spaceXS)
        .nqPlate(NQPanelShape(cut: NQTheme.radiusM), fill: NQTheme.surface, elevation: .soft, inkStroke: true, lineWidth: 2)
    }

    // MARK: - Shop entry

    /// Sits above the section switch — reachable from every pane, since the
    /// coin shop is neither a game nor a crate pull. Deliberately slimmer than
    /// a game row: it's a doorway, and the balance it spends is already shown
    /// just above it.
    private var shopButton: some View {
        Button {
            NQJuice.tap()
            showShop = true
        } label: {
            HStack(spacing: NQTheme.spaceM) {
                NQIconView(icon: .crown, tint: NQTheme.gold)
                    .frame(width: NQLayout.iconXL, height: NQLayout.iconXL)
                Text("Shop")
                    .font(NQText.headingL.font.weight(.heavy))
                    .foregroundStyle(NQTheme.ink)
                Spacer(minLength: 0)
                NQChevron()
            }
            .nqPadding(.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nqSurface(.sticker)
            .overlay {
                NQPanelShape().strokeBorder(NQTheme.gold.opacity(0.5), lineWidth: NQLayout.hairlineWidth)
            }
        }
        .buttonStyle(NQPressableStyle(scale: 0.97, haptic: false))
        .accessibilityHint("Opens the shop")
    }

    // MARK: - Games floor

    private var gamesFloor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceM) {
                header

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: NQTheme.spaceM),
                              GridItem(.flexible(), spacing: NQTheme.spaceM)],
                    spacing: NQTheme.spaceM
                ) {
                    NavigationLink {
                        CauldronCrashView(gameState: gameState)
                    } label: {
                        gameTile(
                            title: "Cauldron Crash",
                            subtitle: "Wager up to 3 · cash out before it blows",
                            icon: .cauldron,
                            tint: NQTheme.warning,
                            game: "cauldron",
                            live: gameState.cauldronRound != nil
                        )
                    }
                    .buttonStyle(NQPressableStyle(scale: 0.97, haptic: false))

                    NavigationLink {
                        KitchenMinesView(gameState: gameState)
                    } label: {
                        gameTile(
                            title: "Kitchen Mines",
                            subtitle: "Lift safe dishes · don't get burnt",
                            icon: .flame,
                            tint: NQTheme.flame,
                            game: "mines",
                            live: gameState.minesRound != nil
                        )
                    }
                    .buttonStyle(NQPressableStyle(scale: 0.97, haptic: false))

                    NavigationLink {
                        PlinkoView(gameState: gameState)
                    } label: {
                        gameTile(
                            title: "Plinko",
                            subtitle: "One drop · no decisions · pure nerve",
                            icon: .chips,
                            tint: NQTheme.info,
                            game: "plinko"
                        )
                    }
                    .buttonStyle(NQPressableStyle(scale: 0.97, haptic: false))

                    NavigationLink {
                        PortalWheelView(gameState: gameState)
                    } label: {
                        gameTile(
                            title: "Portal Wheel",
                            subtitle: "Call the colour · rarer portals pay more",
                            icon: .portal,
                            tint: NQTheme.gold,
                            game: "wheel"
                        )
                    }
                    .buttonStyle(NQPressableStyle(scale: 0.97, haptic: false))
                }

                // Straight off analytics.gamble_hourly. Sits under the
                // cabinets because it is a reason to come back, not a way in.
                CasinoLuckChart()
            }
            .padding(NQTheme.spaceL)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceXS) {
            Text("Risk a monster, win a better one")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
            Text("Wager from your squad. Cash out: or lose the pot.")
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Square, so the floor reads as a row of cabinets rather than a list —
    /// and so a second game slots in beside this one without a redesign.
    private func gameTile(
        title: String,
        subtitle: String,
        icon: NQIcon,
        tint: Color,
        game: String,
        live: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            HStack(alignment: .top) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.18))
                        .frame(width: 56, height: 56)
                    if NQAsset.uiImage(GameArt.gameTile(game)) != nil {
                        NQAssetImage(GameArt.gameTile(game))
                            .frame(width: 56, height: 56)
                    } else {
                        icon.view
                            .frame(width: 22, height: 22)
                            .foregroundStyle(tint)
                    }
                }
                Spacer()
                if live {
                    NQLiveBadge(tint: tint)
                }
            }

            Spacer(minLength: 0)

            Text(title)
                .font(NQText.headingL.font.weight(.bold))
                .foregroundStyle(NQTheme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text(subtitle)
                .font(NQText.captionS.font)
                .foregroundStyle(NQTheme.inkMuted)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .nqPadding(.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aspectRatio(1, contentMode: .fit)
        .nqSurface(.sticker)
        .accessibilityElement(children: .combine)
    }

}

/// The published rules, straight from the server's own config endpoint —
/// the odds a player is offered should be readable before they play, not
/// reverse-engineered afterwards.
struct CauldronOddsView: View {
    @ObservedObject var gameState: GameState

    @Environment(\.dismiss) private var dismiss
    @Environment(\.nqAccent) private var accent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceL) {
                if let config = gameState.cauldronConfig {
                    section("The odds") {
                        Text("The chance a round survives to a multiplier, at a \(Int(config.houseEdge * 100))% house edge.")
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                        ForEach(config.survivalOdds, id: \.multiplier) { odds in
                            HStack {
                                Text(String(format: "%.2fx", odds.multiplier))
                                    .font(NQText.heading.font)
                                    .foregroundStyle(NQTheme.ink)
                                Spacer()
                                Text(String(format: "%.2f%%", odds.chance * 100))
                                    .font(NQText.caption.font.weight(.bold))
                                    .foregroundStyle(NQTheme.inkMuted)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }

                    section("Rarity brackets") {
                        Text("Where your final net worth lands decides which monster comes out.")
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                        ForEach(config.rarityRanges) { range in
                            HStack {
                                Circle()
                                    .fill(Color(hex: range.colorHex))
                                    .frame(width: 10, height: 10)
                                Text(range.label)
                                    .font(NQText.heading.font)
                                    .foregroundStyle(NQTheme.ink)
                                Spacer()
                                Text(range.max.map { "\(range.min.formatted())–\($0.formatted())" }
                                     ?? "\(range.min.formatted())+")
                                    .font(NQText.caption.font.weight(.bold))
                                    .foregroundStyle(NQTheme.inkMuted)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }

                    section("How the crash point is drawn") {
                        Text(config.howItWorks)
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    NQEmptyState(message: "Couldn't reach the house rules.", icon: .wifiOff)
                }
            }
            .padding(NQTheme.spaceL)
        }
        .nqPageBackground()
        .navigationTitle("House rules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task { await gameState.loadCauldronConfig() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NQTheme.spaceS) {
            NQSectionHeader(title)
            content()
        }
        .nqPadding(.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nqSurface(.sticker)
    }
}
