import SwiftUI
import NutriQuestUI

struct CollectionView: View {
    var characters: [Character]
    var activeCharacterID: String?
    var colorMode: ColorMode
    @ObservedObject var gameState: GameState

    @State private var selectedFilter: String = "All"
    @State private var selectedCharacter: Character?
    @State private var carouselIndex = 0
    /// "Sell" mode: tapping the centered card toggles it into the sale
    /// instead of opening its detail sheet.
    @State private var sellMode = false
    @State private var sellSelection: Set<String> = []
    /// "Merge" mode: tapping a card with three matching copies fuses them
    /// into the next star. Mutually exclusive with sell mode.
    @State private var mergeMode = false
    @Environment(\.nqAccent) private var accent

    /// Hero card width — roughly 62% of the screen so neighbors peek at
    /// the sides, capped for larger devices.
    private var carouselCardWidth: CGFloat {
        #if canImport(UIKit)
        return min(UIScreen.main.bounds.width * 0.62, 280)
        #else
        return 240
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NQTheme.spaceM - 2) {
                filterPills
                if displayCharacters.isEmpty {
                    NQEmptyState(message: "No characters discovered yet. Scan food to summon your first one!")
                        .padding(.top, NQTheme.spaceXL)
                } else {
                    NQCoverFlowCarousel(
                        items: displayCharacters,
                        selection: $carouselIndex,
                        cardWidth: carouselCardWidth
                    ) { character, index in
                        carouselCard(for: character, at: index)
                    }
                    .padding(.top, NQTheme.spaceL)
                }
            }
            .padding(NQTheme.spaceL)
        }
        .onAppear(perform: applyLaunchSelection)
        .onChange(of: selectedFilter) { _ in
            // Each collection starts at its first card.
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                carouselIndex = 0
            }
        }
        .nqSceneBackground(GameArt.scene("home"))
        .navigationTitle("My Collection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: NQTheme.spaceS) {
                    mergeModeButton
                    sellModeButton
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if sellMode && !sellSelection.isEmpty { sellBar }
        }
        .sheet(item: $selectedCharacter) { character in
            CharacterDetailView(character: character, gameState: gameState)
                .nqAccentContext(NQAccentContext(mode: .active, character: character.kitColor))
        }
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
            active: mergeMode,
            accessibilityLabel: mergeMode ? "Cancel merging" : "Merge monsters"
        ) {
            mergeMode.toggle()
            if mergeMode {
                sellMode = false
                sellSelection.removeAll()
            }
        }
    }

    private func modeButton(
        title: String,
        active: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            NQHaptic.selection()
            withAnimation(NQMotion.snappy) { action() }
        } label: {
            Text(title)
                .font(NQText.captionS.font.weight(.heavy))
                .foregroundStyle((active ? NQTheme.warning : accent.accent).readableTextColor())
                .nqPadding(.badge)
                .padding(.horizontal, NQTheme.spaceXS)
                .background(Capsule().fill(active ? NQTheme.warning : accent.accent))
        }
        .buttonStyle(NQPressableStyle(scale: 0.95, haptic: false))
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

    /// A hero-sized character card for the carousel. Outside the action
    /// modes, tapping the centered card opens its detail sheet and tapping a
    /// peeking side card scrolls the carousel to it. In sell mode, tapping
    /// the centered card toggles it into the sale; in merge mode, tapping a
    /// card with three matching copies fuses them.
    private func carouselCard(for character: Character, at index: Int) -> some View {
        let isCentered = index == carouselIndex
        let isSelected = sellSelection.contains(character.id)
        return Button {
            if mergeMode {
                guard isCentered, let group = character.mergeableGroup else { scrollTo(index) ; return }
                merge(character, group: group)
            } else if sellMode {
                guard isCentered else { scrollTo(index); return }
                guard character.isSellable else { return }
                NQHaptic.selection()
                withAnimation(NQMotion.snappy) {
                    if isSelected { sellSelection.remove(character.id) } else { sellSelection.insert(character.id) }
                }
            } else if isCentered {
                NQJuice.tap()
                selectedCharacter = character
            } else {
                scrollTo(index)
            }
        } label: {
            NQCharacterCard(
                name: character.name,
                color: character.kitColor,
                rarity: character.rarity.kitRarity,
                statType: character.statType.kitStatType,
                state: state(for: character),
                artwork: character.isLocked ? nil : AnyView(
                    CharacterArtwork(character: character)
                        .frame(width: 128, height: 166)
                ),
                artworkSize: CGSize(width: 128, height: 166)
            )
            .overlay {
                rarityAura(for: character)
            }
            .overlay(alignment: .bottomTrailing) {
                if character.starLevel > 1 && !character.isLocked {
                    Text("★\(character.starLevel)")
                        .font(NQText.captionS.font.weight(.heavy))
                        .foregroundStyle(NQTheme.gold.readableTextColor())
                        .nqPadding(.badge)
                        .padding(.horizontal, NQTheme.spaceXS)
                        .background(Capsule().fill(NQTheme.gold))
                        .padding(NQTheme.spaceS)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if sellMode && !character.isLocked && isCentered {
                    sellIndicator(character: character, isSelected: isSelected)
                } else if mergeMode && !character.isLocked && isCentered {
                    mergeBadge(character: character)
                }
            }
        }
        .buttonStyle(NQPressableStyle(scale: 0.96, haptic: false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(character.name), \(character.rarity.label) rarity\(character.isLocked ? "" : ", \(character.starLevel) star\(character.starLevel == 1 ? "" : "s")")")
        .accessibilityHint(cardHint(for: character, isSelected: isSelected, isCentered: isCentered))
        .nqShineSweep(active: character.rarity >= .legendary)
    }

    private func scrollTo(_ index: Int) {
        NQHaptic.selection()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            carouselIndex = index
        }
    }

    private func cardHint(for character: Character, isSelected: Bool, isCentered: Bool) -> String {
        if mergeMode {
            return character.mergeableGroup != nil
                ? "Double tap to fuse three copies into the next star."
                : "Needs three unlocked copies at the same rarity and star."
        }
        guard sellMode else {
            return isCentered ? "View character details" : "Show this card"
        }
        guard character.isSellable else { return "Not sellable — never picked up as a real drop" }
        return isSelected ? "Selected. Double tap to remove from the sale." : "Double tap to add to the sale."
    }

    /// Overlaid on the centered card: a checkmark toggle when the monster is
    /// a real, sellable drop, a lock when it isn't (an undiscovered
    /// placeholder with no instance behind it).
    private func sellIndicator(character: Character, isSelected: Bool) -> some View {
        Group {
            if character.isSellable {
                ZStack {
                    Circle().fill(isSelected ? accent.accent : Color.black.opacity(0.35))
                    Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(accent.accent.readableTextColor())
                    }
                }
                .frame(width: 30, height: 30)
            } else {
                ZStack {
                    Circle().fill(Color.black.opacity(0.45))
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: 26, height: 26)
            }
        }
        .padding(.top, NQTheme.spaceL)
        .allowsHitTesting(false)
    }

    /// Merge mode's card overlay: a star-up badge when the card holds a
    /// fusable group ("★1 ×3 → ★2"), a lock when it doesn't.
    private func mergeBadge(character: Character) -> some View {
        Group {
            if let group = character.mergeableGroup {
                Text("★\(group.star) ×3 → ★\(group.star + 1)")
                    .font(NQText.tagBold.font)
                    .foregroundStyle(accent.accent.readableTextColor())
                    .nqPadding(.badge)
                    .padding(.horizontal, NQTheme.spaceXS)
                    .background(Capsule().fill(accent.accent))
            } else {
                ZStack {
                    Circle().fill(Color.black.opacity(0.45))
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: 26, height: 26)
            }
        }
        .padding(.top, NQTheme.spaceL)
        .allowsHitTesting(false)
    }

    /// Fire one fusion for the card's lowest eligible group. The inventory
    /// refresh inside mergeCharacters rebuilds the card with the new star.
    private func merge(_ character: Character, group: (star: Int, rarity: String, dropIDs: [String])) {
        NQJuice.success()
        Task {
            _ = await gameState.mergeCharacters(group.dropIDs)
        }
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

    /// Filters the grid by rarity tier. "All" shows every character.
    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NQTheme.spaceS) {
                ForEach(["All"] + Rarity.allCases.map(\.label), id: \.self) { filter in
                    filterPill(filter, selected: selectedFilter == filter)
                }
            }
        }
    }

    /// Fixed size for every filter pill so the row reads as a uniform
    /// grid instead of pills that shrink/grow with their label length.
    private let filterPillSize = CGSize(width: 96, height: 44)

    private func filterPill(_ title: String, selected: Bool) -> some View {
        Button {
            NQHaptic.selection()
            selectedFilter = title
        } label: {
            Text(title)
                .font(NQText.caption.font.weight(.bold))
                .foregroundStyle(selected ? accent.accent.readableTextColor() : NQTheme.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: filterPillSize.width, height: filterPillSize.height)
                .background(
                    RoundedRectangle(cornerRadius: NQTheme.radiusM)
                        .fill(selected ? accent.accent : NQTheme.background)
                )
        }
        .buttonStyle(NQPressableStyle(scale: 0.95, haptic: false))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Unlocked before locked, then rarest first — raw collection order was
    /// whatever order things were scanned/pulled in, which reads as random
    /// once you have more than a handful of characters.
    private var displayCharacters: [Character] {
        var list = colorMode == .none
            ? characters.map { var c = $0; c.isLocked = true; return c }
            : characters
        if selectedFilter != "All" {
            list = list.filter { $0.rarity.label == selectedFilter }
        }
        return list.sorted { a, b in
            if a.isLocked != b.isLocked { return !a.isLocked }
            if a.rarity != b.rarity { return a.rarity > b.rarity }
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
