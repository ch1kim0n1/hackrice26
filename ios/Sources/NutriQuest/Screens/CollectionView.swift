import SwiftUI
import NutriQuestUI

struct CollectionView: View {
    var characters: [Character]
    var activeCharacterID: String?
    var colorMode: ColorMode
    @ObservedObject var gameState: GameState

    @State private var selectedFilter: String = "All"
    /// What the carousel orders by — net worth is the spec's "power level"
    /// (a monster's current worth IS its strength).
    @State private var sortKey: SortKey = .power

    private enum SortKey: String, CaseIterable {
        case power = "Power"
        case level = "Level"
        case rarity = "Rarity"
        case name = "Name"
    }
    @State private var selectedCharacter: Character?
    /// "Sell" mode: tapping a card toggles it into the sale instead of
    /// opening its detail sheet.
    @State private var sellMode = false
    @State private var sellSelection: Set<String> = []
    /// "Merge" mode: tapping a card with three matching copies fuses them
    /// into the next star. Mutually exclusive with sell mode.
    @State private var mergeMode = false
    /// The fusion ceremony: three copies converge while the server fuses,
    /// then the result card reveals — a merge is never silent.
    @State private var mergeFX: MergeFX?
    /// Drives the converge loop while the merge call is in flight.
    @State private var mergeFXSpin = false

    /// One in-flight fusion: which character, which star group, and the
    /// server's answer once it lands.
    private struct MergeFX {
        let character: Character
        let fromStar: Int
        var phase: Phase = .fusing
        var result: MergeResponseDTO?
        enum Phase { case fusing, done, failed }
    }
    @Environment(\.nqAccent) private var accent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceM - 2) {
                filterPills
                sortPills
                if displayCharacters.isEmpty {
                    NQEmptyState(message: mergeMode
                        ? "Nothing to merge: fusion needs three unlocked copies at the same rarity and star."
                        : "No characters discovered yet. Scan food to summon your first one!")
                        .padding(.top, NQTheme.spaceXL)
                } else {
                    // A real grid (#15): every monster visible at once, two
                    // columns like a pokédex page — not a one-card carousel.
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: NQTheme.spaceM),
                        GridItem(.flexible(), spacing: NQTheme.spaceM)
                    ], spacing: NQTheme.spaceM) {
                        ForEach(Array(displayCharacters.enumerated()), id: \.element.id) { index, character in
                            gridCard(for: character)
                                .nqCascade(index: min(index, 7))
                        }
                    }
                    .padding(.top, NQTheme.spaceS)
                }
            }
            .padding(NQTheme.spaceL)
        }
        .onAppear(perform: applyLaunchSelection)
        .nqSceneBackground(GameArt.scene("home"))
        .navigationTitle("Squad")
        .navigationBarTitleDisplayMode(.inline)
        .nqTransparentNav()
        .toolbar {
            ToolbarItem(placement: .principal) {
                NQGameTitle("Squad")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: NQTheme.spaceS) {
                    mergeModeButton
                    sellModeButton
                }
            }
            .nqHideGlass()
        }
        .safeAreaInset(edge: .bottom) {
            if sellMode && !sellSelection.isEmpty { sellBar }
        }
        .sheet(item: $selectedCharacter) { character in
            CharacterDetailView(character: character, gameState: gameState)
                .nqAccentContext(NQAccentContext(mode: .active, character: character.kitColor))
        }
        .overlay { mergeOverlay }
        .task {
            // The collection shouldn't depend on some other screen having
            // already loaded the crate half — refresh it here so a card is
            // sellable the moment its owner opens the tab.
            await gameState.refreshInventory(limit: 200)
        }
    }

    // MARK: - Mode toggles

    /// Toggles sell mode. Exiting it clears whatever was selected.
    private var sellModeButton: some View {
        modeButton(
            title: sellMode ? "Cancel" : "Sell",
            symbol: "dollarsign",
            active: sellMode,
            accessibilityLabel: sellMode ? "Cancel selling" : "Sell monsters"
        ) {
            sellMode.toggle()
            if !sellMode { sellSelection.removeAll() }
            if sellMode { mergeMode = false }
        }
    }

    /// Toggles merge mode. Entering it cancels any sell selection — the two
    /// modes would compete for the same taps.
    private var mergeModeButton: some View {
        modeButton(
            title: mergeMode ? "Cancel" : "Merge",
            symbol: "square.stack.3d.up.fill",
            active: mergeMode,
            accessibilityLabel: mergeMode ? "Cancel merging" : "Merge monsters"
        ) {
            mergeMode.toggle()
            if mergeMode {
                sellMode = false
                sellSelection.removeAll()
                // Merge mode narrows the grid to cards that can actually
                // fuse — the rarity pills reset so a remembered filter can't
                // hide an eligible group.
                selectedFilter = "All"
            }
        }
    }

    private func modeButton(
        title: String,
        symbol: String,
        active: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        let fill = active ? NQTheme.warning : NQTheme.gold
        return Button {
            NQHaptic.selection()
            withAnimation(NQMotion.snappy) { action() }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .heavy))
                Text(title)
                    .font(NQText.microXS.font)
                    .lineLimit(1)
            }
            .foregroundStyle(fill.readableTextColor())
            .frame(width: 56, height: 44)
            .background(NQTicketShape().fill(fill))
            .overlay { NQTicketShape().strokeBorder(NQTheme.inkDeep, lineWidth: 2.5) }
        }
        .buttonStyle(NQPressableStyle(scale: 0.94, haptic: false, ledge: 4))
        .accessibilityLabel(accessibilityLabel)
    }

    /// QA hook on the existing `-uiTab` convention: `-uiCharacter <id>` (or
    /// `first`) opens that card's sheet on launch, so the character sheet can
    /// be captured without a tap.
    private func applyLaunchSelection() {
        guard selectedCharacter == nil else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-uiCharacter"), args.count > i + 1 else { return }
        let wanted = args[i + 1]
        selectedCharacter = wanted == "first"
            ? displayCharacters.first
            : displayCharacters.first { $0.id == wanted || $0.baseID == wanted }
    }

    /// One grid cell (#14, #29): compact card, star badge pinned top-left
    /// (#16), faint marker top-right. Taps open the detail sheet; in sell
    /// mode a tap toggles the card into the sale, in merge mode it fuses a
    /// three-copy group — no "centred card" concept any more.
    private func gridCard(for character: Character) -> some View {
        let isSelected = sellSelection.contains(character.id)
        return Button {
            if mergeMode {
                guard let group = character.mergeableGroup else { return }
                merge(character, group: group)
            } else if sellMode {
                guard character.isSellable else { return }
                NQHaptic.selection()
                withAnimation(NQMotion.snappy) {
                    if isSelected { sellSelection.remove(character.id) } else { sellSelection.insert(character.id) }
                }
            } else {
                NQJuice.tap()
                selectedCharacter = character
            }
        } label: {
            NQCharacterCard(
                name: character.name,
                color: character.kitColor,
                rarity: character.rarity.kitRarity,
                statType: character.statType.kitStatType,
                state: state(for: character),
                artwork: character.isLocked ? nil : AnyView(
                    // Fainted monsters wear the hurt sprite on their card —
                    // the FAINTED badge alone was too easy to miss.
                    CharacterArtwork(character: character, hurt: gameState.faintedIds.contains(character.id))
                        .frame(width: 96, height: 124)
                ),
                artworkSize: CGSize(width: 96, height: 124),
                // Sell/merge/faint badges take the top-right corner — the
                // rarity chip must yield it or the two paint on each other.
                hidesRarityChip: sellMode || mergeMode || gameState.faintedIds.contains(character.id)
            )
            .overlay {
                rarityAura(for: character)
            }
            .overlay(alignment: .topLeading) {
                // Star count lives top-left on every owned card (#16) —
                // drawn as a row of stars, not "★N" text.
                if !character.isLocked {
                    starBadge(character.starLevel)
                        .padding(NQTheme.spaceS)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if sellMode && !character.isLocked {
                    sellIndicator(character: character, isSelected: isSelected)
                } else if mergeMode && !character.isLocked {
                    mergeBadge(character: character)
                } else if gameState.faintedIds.contains(character.id) && !character.isLocked {
                    // Fainted monsters can't be fielded until the daily reset
                    // or a nutrition-task revive (spec §6).
                    Text("Fainted")
                        .font(NQText.microS.font.weight(.heavy))
                        .foregroundStyle(NQTheme.inkFaint.readableTextColor())
                        .nqPadding(.badge)
                        .padding(.horizontal, NQTheme.spaceXS)
                        .background(NQPanelShape(cut: NQTheme.radiusStamp).fill(NQTheme.inkFaint))
                        .padding(NQTheme.spaceS)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(NQPressableStyle(scale: 0.96, haptic: false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(character.name), \(character.rarity.label) rarity\(character.isLocked ? "" : ", \(character.starLevel) star\(character.starLevel == 1 ? "" : "s")")")
        .accessibilityHint(cardHint(for: character, isSelected: isSelected))
        .nqShineSweep(active: character.rarity >= .legendary)
    }

    /// Mastery as drawn stars — ★★★ reads at a glance where "3 stars" text
    /// did not. Five max, so the row never wraps on a card.
    private func starBadge(_ stars: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<max(1, stars), id: \.self) { _ in
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(NQTheme.gold)
                    .shadow(color: NQTheme.inkDeep, radius: 0, y: 1)
            }
        }
        .padding(NQTheme.spaceS)
    }

    private func cardHint(for character: Character, isSelected: Bool) -> String {
        if mergeMode {
            return character.mergeableGroup != nil
                ? "Double tap to fuse three copies into the next star."
                : "Needs three unlocked copies at the same rarity and star."
        }
        guard sellMode else { return "View character details" }
        guard character.isSellable else { return "Not sellable: never picked up as a real drop" }
        return isSelected ? "Selected. Double tap to remove from the sale." : "Double tap to add to the sale."
    }

    /// Sell mode's card corner: a checkmark toggle when the monster is a
    /// real, sellable drop, a lock when it isn't.
    private func sellIndicator(character: Character, isSelected: Bool) -> some View {
        Group {
            if character.isSellable {
                ZStack {
                    Circle().fill(isSelected ? accent.accent : Color.black.opacity(0.35))
                    Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: NQLayout.iconS, weight: .heavy))
                            .foregroundStyle(accent.accent.readableTextColor())
                    }
                }
                .frame(width: 30, height: 30)
            } else {
                ZStack {
                    Circle().fill(Color.black.opacity(0.45))
                    Image(systemName: "lock.fill")
                        .font(.system(size: NQLayout.iconS, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: 26, height: 26)
            }
        }
        .padding(NQTheme.spaceS)
        .allowsHitTesting(false)
    }

    /// Merge mode's card corner: a star-up badge when the card holds a
    /// fusable group ("★1 ×3 → ★2"), a lock when it doesn't.
    private func mergeBadge(character: Character) -> some View {
        Group {
            if let group = character.mergeableGroup {
                Text("★\(group.star) ×3 → ★\(group.star + 1)")
                    .font(NQText.tagBold.font)
                    .foregroundStyle(accent.accent.readableTextColor())
                    .nqPadding(.badge)
                    .padding(.horizontal, NQTheme.spaceXS)
                    .background(NQTicketShape().fill(accent.accent))
                    .overlay {
                        NQTicketShape().strokeBorder(NQTheme.inkDeep, lineWidth: 2)
                    }
            } else {
                ZStack {
                    Circle().fill(Color.black.opacity(0.45))
                    Image(systemName: "lock.fill")
                        .font(.system(size: NQLayout.iconS, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: 26, height: 26)
            }
        }
        .padding(NQTheme.spaceS)
        .allowsHitTesting(false)
    }

    /// Fire one fusion for the card's lowest eligible group. The ceremony
    /// overlay plays while the server fuses — three copies converge, then
    /// the refreshed card reveals itself a star up.
    private func merge(_ character: Character, group: (star: Int, rarity: String, dropIDs: [String])) {
        NQJuice.tap()
        mergeFXSpin = false
        withAnimation(NQMotion.quick) {
            mergeFX = MergeFX(character: character, fromStar: group.star)
        }
        Task {
            async let call = gameState.mergeCharacters(group.dropIDs)
            async let beat: Void = Task.sleep(nanoseconds: 1_100_000_000)
            let (result, _) = await (call, (try? beat) as Void?)
            withAnimation(NQMotion.springy) {
                mergeFX?.result = result
                mergeFX?.phase = result == nil ? .failed : .done
            }
            if result == nil { NQJuice.error() } else { NQJuice.success() }
        }
    }

    /// Full-screen fusion feedback: converge loop while in flight, reveal
    /// card on success, retry affordance on failure.
    @ViewBuilder private var mergeOverlay: some View {
        if let fx = mergeFX {
            ZStack {
                NQTheme.inkDeep.opacity(0.72).ignoresSafeArea()
                if fx.phase == .fusing {
                    fusingStage(fx)
                } else {
                    fusionResult(fx)
                }
            }
            .transition(.opacity)
            .zIndex(30)
        }
    }

    /// The three copies orbit into the centre in a loop until the server
    /// answers — the glow sells "something is happening".
    private func fusingStage(_ fx: MergeFX) -> some View {
        let offsets: [CGSize] = [
            CGSize(width: -96, height: 40),
            CGSize(width: 96, height: 40),
            CGSize(width: 0, height: -100)
        ]
        return VStack(spacing: NQTheme.spaceL) {
            ZStack {
                Circle()
                    .fill(accent.accent.opacity(mergeFXSpin ? 0.5 : 0.15))
                    .frame(width: 200, height: 200)
                    .blur(radius: 40)
                ForEach(0..<3, id: \.self) { i in
                    CharacterArtwork(character: fx.character)
                        .frame(width: 84, height: 108)
                        .offset(mergeFXSpin ? .zero : offsets[i])
                        .rotationEffect(.degrees(mergeFXSpin ? 360 : 0))
                        .scaleEffect(mergeFXSpin ? 0.4 : 1)
                        .opacity(mergeFXSpin ? 0.2 : 1)
                }
            }
            Text("Fusing ★\(fx.fromStar) ×3…")
                .font(NQText.heading.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                mergeFXSpin = true
            }
        }
    }

    /// The reveal: fused artwork big, the star ladder it climbed, and what
    /// it's now worth. The collection refresh already rebuilt the card —
    /// this is the confirmation it actually happened.
    private func fusionResult(_ fx: MergeFX) -> some View {
        let fused = gameState.collection.first { $0.id == fx.character.id } ?? fx.character
        return VStack(spacing: NQTheme.spaceM) {
            if fx.phase == .done {
                Text("Fusion complete")
                    .font(NQText.heading.font.weight(.heavy))
                    .foregroundStyle(NQTheme.gold)
                CharacterArtwork(character: fused)
                    .frame(width: 140, height: 180)
                    .shadow(color: accent.accent.opacity(0.85), radius: 24)
                Text("★\(fx.fromStar) ×3 → ★\(fx.result?.to.star ?? fx.fromStar + 1)")
                    .font(NQText.display.font)
                    .foregroundStyle(NQTheme.ink)
                if let value = fx.result?.to.value {
                    Text("Now worth \(value.formatted()) coins")
                        .font(NQText.captionS.font)
                        .foregroundStyle(NQTheme.inkMuted)
                }
            } else {
                Text("Fusion failed")
                    .font(NQText.heading.font.weight(.heavy))
                    .foregroundStyle(NQTheme.error)
                Text(gameState.backendError ?? "The server refused the merge.")
                    .font(NQText.captionS.font)
                    .foregroundStyle(NQTheme.inkMuted)
                    .multilineTextAlignment(.center)
            }
            NQButton("Done", icon: .checkCircle) {
                withAnimation(NQMotion.quick) { mergeFX = nil }
            }
        }
        .padding(NQTheme.spaceL)
        .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusXL), elevation: .raised)
        .padding(NQTheme.spaceXL)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Sell bar

    private var selectedSellCharacters: [Character] {
        characters.filter { sellSelection.contains($0.id) }
    }

    private var sellTotalNetWorth: Int {
        selectedSellCharacters.reduce(0) { $0 + $1.netWorth }
    }

    /// Sticky footer, matching the Shop's sell bar: a total above one
    /// full-width action button.
    private var sellBar: some View {
        VStack(spacing: NQTheme.spaceS) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(sellSelection.count) selected")
                    .font(NQText.microXS.font)
                    .tracking(0.6)
                    .foregroundStyle(NQTheme.inkMuted)
                Text("\(sellTotalNetWorth.formatted()) coins")
                    .font(NQText.displayL.font)
                    .foregroundStyle(NQTheme.ink)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NQButton(
                gameState.sellBusy ? "Selling…" : "Sell \(sellSelection.count) for \(sellTotalNetWorth.formatted()) coins",
                icon: .checkCircle
            ) {
                sell()
            }
            .disabled(gameState.sellBusy)
        }
        .padding(NQTheme.spaceL)
        .background(NQTheme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(NQTheme.hairline).frame(height: 1) }
    }

    private func sell() {
        let ids = selectedSellCharacters.flatMap(\.dropIDs)
        guard !ids.isEmpty else { return }
        Task {
            if await gameState.sellCharacters(ids) != nil {
                withAnimation(NQMotion.snappy) { sellSelection.removeAll() }
            }
        }
    }

    /// Legendary-and-up gold halo, or an epic purple rim. Compared by rank
    /// so mythic and secret are not left plainer than the tier below them.
    @ViewBuilder
    private func rarityAura(for character: Character) -> some View {
        if character.rarity >= .legendary && !character.isLocked {
            RoundedRectangle(cornerRadius: NQTheme.radiusXL)
                .strokeBorder(NQTheme.gold.opacity(0.45), lineWidth: 2)
                .shadow(color: NQTheme.gold.opacity(0.35), radius: 10)
                .allowsHitTesting(false)
        } else if character.rarity == .epic && !character.isLocked {
            // Epic gets its own aura — a purple rim
            // glow so the tier reads at a glance.
            RoundedRectangle(cornerRadius: NQTheme.radiusXL)
                .strokeBorder(NQRarity.epic.outline.opacity(0.4), lineWidth: 1.5)
                .shadow(color: NQRarity.epic.outline.opacity(0.3), radius: 8)
                .allowsHitTesting(false)
        }
    }

    /// Filters the grid by rarity tier. Underline tabs, not filled capsules.
    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NQTheme.spaceM) {
                ForEach(["All"] + Rarity.allCases.map(\.label), id: \.self) { filter in
                    filterPill(filter, selected: selectedFilter == filter)
                }
            }
        }
    }

    private func filterPill(_ title: String, selected: Bool) -> some View {
        Button {
            NQHaptic.selection()
            selectedFilter = title
        } label: {
            VStack(spacing: 5) {
                Text(title)
                    .font(NQText.caption.font.weight(.heavy))
                    .foregroundStyle(selected ? NQTheme.gold : NQTheme.inkMuted)
                Rectangle()
                    .fill(selected ? NQTheme.gold : Color.clear)
                    .frame(height: 3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Sort as underlined keys, matching the rarity tabs.
    private var sortPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NQTheme.spaceM) {
                Text("Sort")
                    .font(NQText.micro.font.weight(.bold))
                    .foregroundStyle(NQTheme.inkFaint)
                ForEach(SortKey.allCases, id: \.self) { key in
                    sortPill(key)
                }
            }
        }
    }

    private func sortPill(_ key: SortKey) -> some View {
        let selected = sortKey == key
        return Button {
            NQHaptic.selection()
            sortKey = key
        } label: {
            VStack(spacing: 5) {
                Text(key.rawValue)
                    .font(NQText.caption.font.weight(.heavy))
                    .foregroundStyle(selected ? NQTheme.gold : NQTheme.inkMuted)
                Rectangle()
                    .fill(selected ? NQTheme.gold : Color.clear)
                    .frame(height: 3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("Sort by \(key.rawValue)")
    }

    /// Unlocked before locked, then by the chosen sort key — raw collection
    /// order was whatever order things were scanned/pulled in, which reads
    /// as random once you have more than a handful of characters.
    private var displayCharacters: [Character] {
        var list = colorMode == .none
            ? characters.map { var c = $0; c.isLocked = true; return c }
            : characters
        if mergeMode {
            list = list.filter { $0.mergeableGroup != nil }
        }
        if selectedFilter != "All" {
            list = list.filter { $0.rarity.label == selectedFilter }
        }
        return list.sorted { a, b in
            if a.isLocked != b.isLocked { return !a.isLocked }
            switch sortKey {
            case .power:
                if a.netWorth != b.netWorth { return a.netWorth > b.netWorth }
                if a.rarity != b.rarity { return a.rarity > b.rarity }
            case .level:
                if a.starLevel != b.starLevel { return a.starLevel > b.starLevel }
                if a.rarity != b.rarity { return a.rarity > b.rarity }
            case .rarity:
                if a.rarity != b.rarity { return a.rarity > b.rarity }
            case .name:
                return a.name < b.name
            }
            return a.name < b.name
        }
    }

    private func state(for character: Character) -> NQCharacterCard.State {
        guard !character.isLocked else { return .locked }
        if colorMode == .active, character.id == activeCharacterID { return .active }
        if colorMode == .bestUnselected, character.id == bestCharacterID { return .suggested }
        return .normal
    }

    private var bestCharacterID: String? {
        // Rarity is Comparable by scarcity, so no local rank table to keep in
        // step with the ladder.
        characters.filter { !$0.isLocked }.max(by: { $0.rarity < $1.rarity })?.id
    }
}
