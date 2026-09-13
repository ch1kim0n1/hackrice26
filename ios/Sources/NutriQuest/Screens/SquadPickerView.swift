import SwiftUI
import NutriQuestUI

/// Pick three characters for a LAN battle. Tap order is battle order — the
/// engine always attacks the first living enemy, so the lead matters.
///
/// Your pick is committed blind: the opponent can't see it until both of you
/// have locked in, so there's no counter-picking.
struct SquadPickerView: View {
    let characters: [Character]
    let opponentName: String
    let deadline: Date
    let onLockIn: ([Character]) -> Void

    @State private var selected: [String]
    @State private var locked = false
    @Environment(\.nqAccent) private var accent

    static let lastSquadKey = "lan.lastSquad"

    init(characters: [Character], opponentName: String, deadline: Date, onLockIn: @escaping ([Character]) -> Void) {
        self.characters = characters
        self.opponentName = opponentName
        self.deadline = deadline
        self.onLockIn = onLockIn
        // Start from last time's squad when it's still in the collection.
        let saved = UserDefaults.standard.stringArray(forKey: Self.lastSquadKey) ?? []
        let stillOwned = saved.filter { id in characters.contains { $0.id == id } }
        _selected = State(initialValue: stillOwned.count == 3 ? stillOwned : Array(characters.prefix(3).map(\.id)))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: NQTheme.spaceL) {
                header

                if characters.count < 3 {
                    NQBanner.warning("You need at least three characters to battle. Scan some food first!")
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: NQTheme.spaceM) {
                    ForEach(characters) { character in
                        card(character)
                    }
                }

                NQButton(lockTitle, icon: .lock) { lockIn() }
                    .disabled(selected.count != 3 || locked)
            }
            .padding(NQTheme.spaceL)
        }
        .nqPageBackground()
        .navigationTitle("Pick your squad")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var lockTitle: String {
        if locked { return "Locked in" }
        return selected.count == 3 ? "Lock in squad" : "Pick \(3 - selected.count) more"
    }

    private var header: some View {
        VStack(spacing: NQTheme.spaceS) {
            Text("vs \(opponentName)")
                .font(NQText.headingL.font.weight(.heavy))
                .foregroundStyle(NQTheme.ink)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                Text("\(remaining)s to lock in · tap order is battle order")
                    .font(NQText.captionS.font.weight(.semibold))
                    .foregroundStyle(remaining <= 10 ? NQTheme.warning : NQTheme.inkMuted)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func card(_ character: Character) -> some View {
        let position = selected.firstIndex(of: character.id)
        return Button {
            toggle(character.id)
        } label: {
            NQCharacterCard(
                name: character.name,
                color: character.kitColor,
                rarity: character.rarity.kitRarity,
                statType: character.statType.kitStatType,
                state: position == nil ? .normal : .active,
                artwork: AnyView(
                    CharacterArtwork(character: character)
                        .frame(width: 80, height: 104)
                ),
            )
            .overlay(alignment: .topLeading) {
                if let position {
                    Text("\(position + 1)")
                        .font(NQText.caption.font.weight(.heavy))
                        .foregroundStyle(accent.accent.readableTextColor())
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(accent.accent))
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .accessibilityLabel(position.map { "\(character.name), slot \($0 + 1)" } ?? character.name)
        .accessibilityAddTraits(position == nil ? [] : .isSelected)
    }

    private func toggle(_ id: String) {
        NQJuice.tap()
        if let index = selected.firstIndex(of: id) {
            selected.remove(at: index)
        } else if selected.count < 3 {
            selected.append(id)
        }
    }

    private func lockIn() {
        let squad = selected.compactMap { id in characters.first { $0.id == id } }
        guard squad.count == 3 else { return }
        locked = true
        UserDefaults.standard.set(selected, forKey: Self.lastSquadKey)
        onLockIn(squad)
    }
}
