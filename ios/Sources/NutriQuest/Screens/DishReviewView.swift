import SwiftUI
import NutriQuestUI

/// One row of the review screen, holding the user's in-progress corrections.
///
/// Nutrition is always derived from the *analysed* item by scaling on portion,
/// which mirrors `scaleItem()` in backend/src/nutrition/totals.ts exactly — so
/// the totals shown here are the same ones the server will recompute on
/// confirm. The client never invents nutrient values.
struct EditableDishItem: Identifiable, Equatable {
    let original: DishItemDTO
    var name: String
    var portionG: Double
    var removed: Bool

    var id: String { original.id }

    init(_ item: DishItemDTO) {
        self.original = item
        self.name = item.name
        self.portionG = item.portionG
        self.removed = false
    }

    /// Density-preserving scale factor against the analysed portion.
    private var factor: Double {
        guard original.portionG > 0 else { return 0 }
        return portionG / original.portionG
    }

    var calories: Double { original.calories * factor }
    var proteinG: Double { original.proteinG * factor }
    var carbsG: Double { original.carbsG * factor }
    var fatG: Double { original.fatG * factor }
    var fiberG: Double { original.fiberG * factor }
    var sugarG: Double { original.sugarG * factor }

    /// Counts toward the plate only while it's still on it.
    var isActive: Bool { !removed && portionG > 0 }

    /// The correction to send, or nil when the user left this item alone.
    var edit: DishItemEdit? {
        if removed { return DishItemEdit(id: id, removed: true) }
        let renamed = name != original.name && !name.trimmingCharacters(in: .whitespaces).isEmpty
        let reportioned = abs(portionG - original.portionG) > 0.5
        guard renamed || reportioned else { return nil }
        return DishItemEdit(
            id: id,
            name: renamed ? name : nil,
            portionG: reportioned ? portionG : nil,
            removed: nil
        )
    }
}

/// The confirm-and-correct step: the user sees every food the analysis found,
/// fixes what's wrong, and only then logs the plate as a meal.
///
/// A photographed dish is always an estimate — the screen says so plainly —
/// and it never mints a monster. This review step is what makes a photo-only
/// guess safe enough to write into the meal log.
struct DishReviewView: View {
    let analysis: DishAnalysisDTO
    let isConfirming: Bool
    let onConfirm: ([DishItemEdit]) -> Void
    let onRetake: () -> Void

    @State private var items: [EditableDishItem]
    @Environment(\.nqAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    init(
        analysis: DishAnalysisDTO,
        isConfirming: Bool,
        onConfirm: @escaping ([DishItemEdit]) -> Void,
        onRetake: @escaping () -> Void
    ) {
        self.analysis = analysis
        self.isConfirming = isConfirming
        self.onConfirm = onConfirm
        self.onRetake = onRetake
        _items = State(initialValue: analysis.items.map(EditableDishItem.init))
    }

    private var active: [EditableDishItem] { items.filter(\.isActive) }
    private var totalCalories: Double { active.reduce(0) { $0 + $1.calories } }
    private var totalProtein: Double { active.reduce(0) { $0 + $1.proteinG } }
    private var totalCarbs: Double { active.reduce(0) { $0 + $1.carbsG } }
    private var totalFat: Double { active.reduce(0) { $0 + $1.fatG } }
    private var totalFiber: Double { active.reduce(0) { $0 + $1.fiberG } }
    private var plateIsEmpty: Bool { active.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: NQTheme.spaceL) {
                    if analysis.lowConfidence {
                        NQBanner(
                            "This one was hard to read — double-check the items before you log it.",
                            dotColor: NQTheme.warning
                        )
                    }

                    totalsCard

                    VStack(alignment: .leading, spacing: NQTheme.spaceS) {
                        Text("What's on the plate")
                            .font(NQText.caption.font.weight(.bold))
                            .foregroundStyle(NQTheme.inkMuted)
                        Text("Adjust a portion, rename an item, or remove anything that isn't there.")
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.inkFaint)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    ForEach($items) { $item in
                        itemRow($item)
                    }

                    if plateIsEmpty {
                        NQBanner.error("Nothing left on the plate. Put an item back, or retake the photo.")
                    }

                    actions
                }
                .padding(NQTheme.spaceL)
            }
            .nqPageBackground()
            .navigationTitle("Check your plate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isConfirming)
                }
            }
        }
    }

    // MARK: - Totals

    private var totalsCard: some View {
        NQCard {
            VStack(alignment: .leading, spacing: NQTheme.spaceM) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(analysis.dishName)
                            .font(NQText.heading.font)
                            .foregroundStyle(NQTheme.ink)
                        // Photo numbers are always labelled as estimates —
                        // the user is the check on the vision model, not the
                        // other way round.
                        Text("Estimated from photo · \(active.count) item\(active.count == 1 ? "" : "s") · \(Int(active.reduce(0) { $0 + $1.portionG })) g")
                            .font(NQText.captionS.font)
                            .foregroundStyle(NQTheme.inkFaint)
                    }
                    Spacer()
                    Text("\(Int(totalCalories.rounded())) kcal")
                        .font(NQText.headingL.font.weight(.heavy))
                        .foregroundStyle(accent.accentDark)
                        .contentTransition(.numericText())
                }

                HStack(spacing: NQTheme.spaceS) {
                    macroPill("Protein", totalProtein, NQTheme.flame)
                    macroPill("Carbs", totalCarbs, NQTheme.info)
                    macroPill("Fat", totalFat, NQTheme.gold)
                    macroPill("Fiber", totalFiber, NQTheme.success)
                }
            }
        }
        .animation(NQMotion.quick, value: totalCalories)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(analysis.dishName). \(Int(totalCalories.rounded())) kilocalories, "
            + "\(Int(totalProtein)) grams protein, \(Int(totalCarbs)) grams carbs, "
            + "\(Int(totalFat)) grams fat, \(Int(totalFiber)) grams fiber."
        )
    }

    private func macroPill(_ label: String, _ value: Double, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(label.uppercased())
                .font(NQText.micro.font.weight(.bold))
                .foregroundStyle(tint)
            Text("\(Int(value.rounded()))g")
                .font(NQText.captionS.font.weight(.semibold))
                .foregroundStyle(NQTheme.ink)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusM))
    }

    // MARK: - Item row

    private func itemRow(_ item: Binding<EditableDishItem>) -> some View {
        let value = item.wrappedValue
        // Allow generous headroom for a portion the analysis underestimated,
        // while keeping the slider usable for small items.
        let maxPortion = max(value.original.portionG * 2.5, 100).rounded()

        return NQCard {
            VStack(alignment: .leading, spacing: NQTheme.spaceS) {
                HStack(spacing: NQTheme.spaceS) {
                    TextField("Item name", text: item.name)
                        .font(NQText.body.font.weight(.semibold))
                        .foregroundStyle(value.removed ? NQTheme.inkFaint : NQTheme.ink)
                        .strikethrough(value.removed)
                        .disabled(value.removed)

                    Button {
                        withAnimation(NQMotion.quick) { item.removed.wrappedValue.toggle() }
                        NQJuice.tap()
                    } label: {
                        Image(systemName: value.removed ? "arrow.uturn.backward.circle" : "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(value.removed ? accent.accentDark : NQTheme.inkFaint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(value.removed ? "Put \(value.name) back on the plate" : "Remove \(value.name)")
                }

                if !value.removed {
                    HStack(spacing: NQTheme.spaceS) {
                        NQChip(foodGroupLabel(value.original.foodGroup), tint: groupTint(value.original.foodGroup))
                        if value.original.confidence < 0.5 {
                            NQChip("unsure", icon: .alert, tint: NQTheme.warning)
                        }
                        Spacer()
                        Text("\(Int(value.calories.rounded())) kcal")
                            .font(NQText.captionS.font.weight(.bold))
                            .foregroundStyle(NQTheme.inkMuted)
                            .contentTransition(.numericText())
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Portion")
                                .font(NQText.micro.font.weight(.bold))
                                .foregroundStyle(NQTheme.inkFaint)
                            Spacer()
                            Text("\(Int(value.portionG.rounded())) g")
                                .font(NQText.captionS.font.weight(.semibold))
                                .foregroundStyle(NQTheme.ink)
                                .contentTransition(.numericText())
                        }
                        Slider(value: item.portionG, in: 0...maxPortion, step: 5)
                            .tint(accent.accent)
                            .accessibilityLabel("\(value.name) portion in grams")
                            .accessibilityValue("\(Int(value.portionG.rounded())) grams")
                    }

                    Text("P \(Int(value.proteinG))g · C \(Int(value.carbsG))g · F \(Int(value.fatG))g · Fib \(Int(value.fiberG))g")
                        .font(NQText.micro.font)
                        .foregroundStyle(NQTheme.inkFaint)
                }
            }
        }
        .opacity(value.removed ? 0.55 : 1)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: NQTheme.spaceS) {
            NQButton(isConfirming ? "Logging…" : "Looks right — log this meal", icon: .checkCircle) {
                onConfirm(items.compactMap(\.edit))
            }
            .disabled(plateIsEmpty || isConfirming)

            NQButton("Retake photo", icon: .scan, style: .secondary) {
                onRetake()
            }
            .disabled(isConfirming)
        }
    }

    // MARK: - Helpers

    private func foodGroupLabel(_ group: String) -> String {
        switch group {
        case "produce": return "Produce"
        case "grain": return "Grain"
        case "dairy": return "Dairy"
        case "protein": return "Protein"
        default: return "Other"
        }
    }

    private func groupTint(_ group: String) -> Color {
        switch group {
        case "produce": return NQTheme.success
        case "grain": return NQTheme.gold
        case "dairy": return NQTheme.info
        case "protein": return NQTheme.flame
        default: return NQTheme.inkMuted
        }
    }
}
