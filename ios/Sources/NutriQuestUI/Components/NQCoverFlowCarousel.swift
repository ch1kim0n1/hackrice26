import SwiftUI

// MARK: - Cover-flow carousel

/// Cover-flow style card carousel: the centered card renders at full size
/// while its neighbors peek from the sides with scale, Y-axis rotation, and
/// dimming for depth. Swipe left/right to move to the next or previous card;
/// releasing a drag snaps to the nearest card and a quick flick advances one
/// card even on a short drag. The ends rubber-band instead of scrolling past.
///
/// iOS 16 compatible — built on a manual `DragGesture` rather than the
/// iOS 17 `scrollTransition` APIs.
public struct NQCoverFlowCarousel<Item: Identifiable, Content: View>: View {
    private let items: [Item]
    @Binding private var selection: Int
    private let cardWidth: CGFloat
    private let spacing: CGFloat
    private let content: (Item, Int) -> Content

    /// Live horizontal drag translation while a swipe is in flight.
    @State private var dragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Creates a cover-flow carousel.
    /// - Parameters:
    ///   - items: The identifiable items to page through.
    ///   - selection: Binding to the index of the centered card.
    ///   - cardWidth: Width of each card; height follows the content.
    ///   - spacing: Gap between adjacent card centers beyond the card width.
    ///   - content: Builds the card for an item; also receives the item index.
    public init(
        items: [Item],
        selection: Binding<Int>,
        cardWidth: CGFloat,
        spacing: CGFloat = NQTheme.spaceM,
        @ViewBuilder content: @escaping (Item, Int) -> Content
    ) {
        self.items = items
        self._selection = selection
        self.cardWidth = cardWidth
        self.spacing = spacing
        self.content = content
    }

    /// Distance between adjacent card centers.
    private var step: CGFloat { cardWidth + spacing }

    /// Current fractional position along the strip, including live drag and
    /// rubber-band resistance past either end.
    private var position: CGFloat {
        let raw = CGFloat(clampedSelection) - dragOffset / step
        let maxIndex = CGFloat(max(items.count - 1, 0))
        if raw < 0 { return raw / 3 }
        if raw > maxIndex { return maxIndex + (raw - maxIndex) / 3 }
        return raw
    }

    /// Selection clamped to the valid range, guarding against item-list
    /// changes that shrink the collection under the bound index.
    private var clampedSelection: Int {
        min(max(selection, 0), max(items.count - 1, 0))
    }

    public var body: some View {
        VStack(spacing: NQTheme.spaceM) {
            ZStack {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    card(for: item, at: index)
                }
            }
            .frame(maxWidth: .infinity)
            .gesture(dragGesture)
            pageIndicator
        }
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(to: clampedSelection + 1)
            case .decrement: move(to: clampedSelection - 1)
            @unknown default: break
            }
        }
        .onChange(of: items.count) { _ in
            // Keep the centered card valid when the collection shrinks.
            if selection > items.count - 1 {
                selection = max(items.count - 1, 0)
            }
        }
    }

    /// A single positioned, transformed card in the strip.
    private func card(for item: Item, at index: Int) -> some View {
        // Signed distance from this card to the visual center, in card slots.
        let distance = CGFloat(index) - position
        let magnitude = abs(distance)

        return content(item, index)
            .frame(width: cardWidth)
            // Flatten the card (background, artwork, chips, text) into a
            // single layer so the transforms below apply to one opaque
            // surface instead of blending each sublayer separately —
            // otherwise the rarity chip and name text look doubled where
            // cards overlap.
            .compositingGroup()
            .scaleEffect(max(0.78, 1 - magnitude * 0.16))
            .rotation3DEffect(
                reduceMotion ? .zero : .degrees(-min(max(distance, -1.5), 1.5) * 28),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.6
            )
            // Depth is conveyed by dimming, not transparency: side cards
            // stay fully opaque so the card behind never shows through.
            // Only far offscreen cards fade out entirely so they cannot
            // stack up while animating across the strip.
            .brightness(-min(magnitude, 1.5) * 0.07)
            .opacity(magnitude < 1.5 ? 1 : max(0, 1 - (magnitude - 1.5) * 2))
            .offset(x: distance * step)
            .zIndex(-magnitude)
            // The scale/offset/rotation above are layout — they place the
            // strip, so Reduce Motion can't drop them without collapsing the
            // cover flow into a stack. What it does drop is the travel
            // between selections: the card snaps to its new place instead.
            .animation(reduceMotion ? nil : NQMotion.carousel, value: selection)
    }

    /// Drag gesture that tracks the strip live and snaps on release.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let travelled = -value.translation.width / step
                var target = clampedSelection + Int(travelled.rounded())
                // A quick flick advances one card even on a short drag.
                let flick = value.predictedEndTranslation.width - value.translation.width
                if target == clampedSelection && abs(flick) > 60 {
                    target += flick < 0 ? 1 : -1
                }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                    dragOffset = 0
                }
                move(to: target)
            }
    }

    /// Animates the centered card to `target`, clamped to the valid range,
    /// with a selection haptic when the card actually changes.
    private func move(to target: Int) {
        let clamped = min(max(target, 0), max(items.count - 1, 0))
        guard clamped != clampedSelection else { return }
        NQHaptic.selection()
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            selection = clamped
        }
    }

    /// Dots for small collections, a compact "3 / 12" counter for large ones.
    @ViewBuilder
    private var pageIndicator: some View {
        if items.count > 1 {
            if items.count <= 8 {
                HStack(spacing: NQTheme.spaceXS + 2) {
                    ForEach(0..<items.count, id: \.self) { index in
                        Circle()
                            .fill(index == clampedSelection ? NQTheme.ink : NQTheme.inkFaint)
                            .frame(width: index == clampedSelection ? 8 : 6, height: index == clampedSelection ? 8 : 6)
                            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: clampedSelection)
                    }
                }
                .accessibilityHidden(true)
            } else {
                Text("\(clampedSelection + 1) / \(items.count)")
                    .font(NQText.caption.font.weight(.bold))
                    .foregroundStyle(NQTheme.inkMuted)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
    }
}
