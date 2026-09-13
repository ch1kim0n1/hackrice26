import SwiftUI

/// Framed adventure-menu panel with standard padding and depth.
///
/// `style` picks the surface: `.sticker` (the default die-cut card with an
/// ink edge) for top-level content, `.card` for a surface nested inside
/// another one, where a second ink stroke reads as clutter.
public struct NQCard<Content: View>: View {
    private let style: NQSurfaceStyle
    private let content: Content

    public init(_ style: NQSurfaceStyle = .sticker, @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    public var body: some View {
        content
            .nqPadding(.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nqSurface(style)
    }
}

// MARK: - Character card (Collection)

/// The shared Collection card, matching design/CharacterCard.dc.html:
/// white card with rarity ring, chibi preview, rarity stamp top-right,
/// optional ACTIVE / SUGGESTED stamp under the name, and a mystery
/// silhouette with a lock for locked characters.
public struct NQCharacterCard: View {
    public enum State { case normal, active, suggested, locked, loading }

    private let name: String
    private let color: NQCharacterColor
    private let rarity: NQRarity
    private let statType: NQStatType
    private let state: State
    private let expression: ChibiExpression
    private let artwork: AnyView?
    private let shiny: Bool
    private let artworkSize: CGSize
    /// When a screen pins its own badge top-right (faint, sell, merge), the
    /// built-in rarity chip would sit on top of it — this hides it.
    private let hidesRarityChip: Bool

    /// Creates a character card.
    /// - Parameter artworkSize: Frame for the chibi/artwork area; defaults to
    ///   the standard grid size, pass a larger size for hero presentations.
    public init(
        name: String,
        color: NQCharacterColor,
        rarity: NQRarity,
        statType: NQStatType,
        state: State = .normal,
        expression: ChibiExpression = .happy,
        artwork: AnyView? = nil,
        shiny: Bool = false,
        artworkSize: CGSize = CGSize(width: 80, height: 104),
        hidesRarityChip: Bool = false
    ) {
        self.name = name
        self.color = color
        self.rarity = rarity
        self.statType = statType
        self.state = state
        self.expression = expression
        self.artwork = artwork
        self.shiny = shiny
        self.artworkSize = artworkSize
        self.hidesRarityChip = hidesRarityChip
    }

    public var body: some View {
        Group {
            if state == .loading {
                loadingBody
            } else {
                resolvedBody
            }
        }
    }

    /// Skeleton stand-in — distinct from every other state (nothing to
    /// reveal yet, not even a locked silhouette), so a grid that is still
    /// fetching never reads as simply broken.
    private var loadingBody: some View {
        VStack(spacing: NQTheme.spaceXS + 2) {
            NQSkeleton(width: artworkSize.width, height: artworkSize.height, cornerRadius: NQTheme.radiusL)
                .padding(.top, NQTheme.spaceS)
            NQSkeleton(width: artworkSize.width * 0.7, height: 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, NQTheme.spaceL)
        .padding(.bottom, NQTheme.spaceM)
        .background {
            NQPanelShape(cut: NQTheme.radiusM)
                .fill(NQTheme.background)
                .nqElevation(.raised)
        }
        .clipShape(NQPanelShape(cut: NQTheme.radiusM))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading character")
    }

    private var resolvedBody: some View {
        VStack(spacing: NQTheme.spaceXS + 2) {
            Group {
                if let artwork, state != .locked {
                    artwork
                } else {
                    ChibiCharacterView(
                        color: color,
                        statType: statType,
                        expression: state == .locked ? .sleepy : expression,
                        showFace: state != .locked,
                        silhouette: state == .locked
                    )
                }
            }
            .frame(width: artworkSize.width, height: artworkSize.height)
            .overlay {
                if state != .locked, let frame = NQAsset.uiImage("\(rarity.rawValue)-frame") {
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFit()
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if (rarity == .secret || shiny) && state != .locked,
                   let foil = NQAsset.uiImage("nutriquest-holographic-foil-overlay-512x640") {
                    Image(uiImage: foil)
                        .resizable()
                        .scaledToFit()
                        .opacity(0.32)
                        .blendMode(.overlay)
                        .allowsHitTesting(false)
                }
            }
            // Oversized (hero) artwork gets extra top clearance so it never
            // slides under the rarity chip pinned to the top-right corner.
            .padding(.top, NQTheme.spaceS + max(0, (artworkSize.height - 104) * 0.3))
            .opacity(state == .locked ? 0.9 : 1)

            Text(state == .locked ? "???" : name)
                .font(NQText.heading.font)
                .foregroundStyle(state == .locked ? NQTheme.inkFaint : NQTheme.ink)
                .lineLimit(1)
            if state == .active {
                Text("Active")
                    .font(NQText.microS.font)
                    .foregroundStyle(NQTheme.gold)
                    .shadow(color: NQTheme.inkDeep, radius: 0, y: 1)
            } else if state == .suggested {
                Text("Suggested")
                    .font(NQText.microS.font)
                    .foregroundStyle(NQTheme.accentDark)
                    .shadow(color: NQTheme.inkDeep, radius: 0, y: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, NQTheme.spaceL)
        .padding(.bottom, NQTheme.spaceM)
        .background {
            NQPanelShape(cut: NQTheme.radiusM)
                .fill(state == .locked ? NQTheme.chrome : NQTheme.background)
                .nqElevation(.raised)
        }
        .clipShape(NQPanelShape(cut: NQTheme.radiusM))
        .overlay {
            // Locked cards still need a rarity-neutral ring (there's no
            // artwork frame to draw when there's nothing to frame). Unlocked
            // cards get their rarity color from the octagonal `-frame` art
            // around the portrait now — except Secret, whose identity is the
            // black card edge.
            if state == .locked {
                NQPanelShape(cut: NQTheme.radiusM)
                    .strokeBorder(NQTheme.inkRule, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            } else if rarity == .secret {
                NQPanelShape(cut: NQTheme.radiusM)
                    .strokeBorder(Color.black, lineWidth: rarity.outlineWidth)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !hidesRarityChip && state != .locked {
                rarityChip
            }
        }
        .overlay(alignment: .top) {
            if state == .locked {
                // Centered over the chibi; 34pt at the default 104pt artwork
                // height, scaled proportionally for hero-sized cards.
                lockBadge.offset(y: artworkSize.height * 0.327)
            }
        }
        .overlay {
            // Shiny variant: gold frame edge.
            if shiny && state != .locked {
                NQPanelShape(cut: NQTheme.radiusM).inset(by: 3)
                    .strokeBorder(NQTheme.gold.opacity(0.8), lineWidth: 1.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            state == .locked
                ? "Locked character"
                : "\(name), \(shiny ? "shiny " : "")\(rarity.displayName) rarity\(state == .active ? ", active" : state == .suggested ? ", suggested" : "")"
        )
    }

    /// Rarity as a corner fold — a rectangle, not a chip.
    private var rarityChip: some View {
        Text(rarity.displayName)
            .font(NQText.microS.font)
            .foregroundStyle(rarity.outline.readableTextColor())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Rectangle().fill(rarity.outline))
            .overlay { Rectangle().strokeBorder(NQTheme.inkDeep, lineWidth: 2) }
            .rotationEffect(.degrees(8))
            .padding(.top, 10)
            .padding(.trailing, 4)
    }

    /// Gold lock stamp over the mystery silhouette.
    private var lockBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .circular)
                .fill(NQTheme.gold)
                .frame(width: 40, height: 40)
            RoundedRectangle(cornerRadius: 5, style: .circular)
                .strokeBorder(NQTheme.inkDeep, lineWidth: 2.5)
                .frame(width: 40, height: 40)
            NQIcon.lock.view
                .frame(width: 20, height: 20)
                .foregroundStyle(NQTheme.inkDeep)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Empty state

/// Dashed circle + message — the "no characters yet" pattern.
public struct NQEmptyState: View {
    private let message: String
    private var icon: NQIcon
    /// Optional stand-in for the icon — pass a mascot so an empty screen is
    /// still the app's own character rather than a generic placeholder.
    private var artwork: AnyView?
    /// Optional call to action — an empty state whose copy implies a next
    /// step ("open a crate and come back") needs a real button, not just text.
    private var actionLabel: String?
    private var action: (() -> Void)?

    @Environment(\.nqAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    public init(
        message: String,
        icon: NQIcon = .sparkle,
        artwork: AnyView? = nil,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.message = message
        self.icon = icon
        self.artwork = artwork
        self.actionLabel = actionLabel
        self.action = action
    }

    public var body: some View {
        VStack(spacing: NQTheme.spaceM) {
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                .foregroundStyle(accent.accent)
                .frame(width: 150, height: 150)
                .overlay {
                    if let artwork {
                        artwork.frame(width: 104, height: 135)
                    } else if let mascot = NQAsset.uiImage("gatekeeper-mascot") {
                        Image(uiImage: mascot)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 104, height: 135)
                    } else {
                        icon.view
                            .frame(width: 36, height: 36)
                            .foregroundStyle(accent.accent)
                    }
                }
                // A slow breathing scale — an invitation, not an inert
                // placeholder. Empty should feel different from broken.
                .scaleEffect(breathing ? 1.05 : 1)
                .opacity(breathing ? 1 : 0.85)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                        breathing = true
                    }
                }
            Text(message)
                .font(NQText.bodyL.font)
                .foregroundStyle(NQTheme.inkMuted)
                .multilineTextAlignment(.center)
            if let actionLabel, let action {
                NQButton(actionLabel, style: .primary, fullWidth: false) { action() }
                    .padding(.top, NQTheme.spaceXS)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
