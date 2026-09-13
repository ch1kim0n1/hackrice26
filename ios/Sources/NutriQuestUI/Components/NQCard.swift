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
/// white card with rarity ring, chibi preview, rarity chip top-right,
/// optional ACTIVE / SUGGESTED pill top-center, and a faceless "???" body
/// with a lock for locked characters.
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
        artworkSize: CGSize = CGSize(width: 80, height: 104)
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
                        showFace: state != .locked
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
        }
        .frame(maxWidth: .infinity)
        .padding(.top, NQTheme.spaceL)
        .padding(.bottom, NQTheme.spaceM)
        .background {
            NQPanelShape(cut: NQTheme.radiusM)
                .fill(NQTheme.background)
                // Real depth instead of a flat outline standing in for it —
                // this is the level the design system already names for
                // "character cards, modals" but hadn't reached this card yet.
                .nqElevation(.raised)
        }
        .clipShape(NQPanelShape(cut: NQTheme.radiusM))
        .overlay {
            // Locked cards still need a rarity-neutral ring (there's no
            // artwork frame to draw when there's nothing to frame). Unlocked
            // cards get their rarity color from the octagonal `-frame` art
            // around the portrait now — an outer card-wide stroke on top of
            // that was two borders doing the same job.
            if state == .locked {
                NQPanelShape(cut: NQTheme.radiusM)
                    .strokeBorder(NQTheme.inkRule, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
        }
        .overlay(alignment: .top) {
            if state != .normal && state != .locked {
                stateBadge.padding(.top, -9)
            }
        }
        .overlay(alignment: .topTrailing) {
            rarityChip.padding(NQTheme.spaceS + 2)
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

    /// Active / Suggested pill, top-center.
    private var stateBadge: some View {
        Text(state == .active ? "Active" : "Suggested")
            .font(NQText.microS.font)
            .foregroundStyle(state == .active ? color.accent.readableTextColor() : color.accentDark)
            .nqPadding(.badge)
            .background(
                NQPanelShape(cut: NQTheme.radiusXS).fill(state == .active ? color.accent : color.accentSoft)
            )
            .overlay { NQPanelShape(cut: NQTheme.radiusXS).strokeBorder(NQTheme.gold.opacity(0.5), lineWidth: 1) }
    }

    /// Rarity label chip, top-right.
    private var rarityChip: some View {
        Text(rarity.displayName)
            .font(NQText.tagBold.font)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(rarity.badgeText)
            .nqPadding(.badge)
            .background(NQPanelShape(cut: NQTheme.radiusXS).fill(rarity.badgeBackground))
            .overlay {
                NQPanelShape(cut: NQTheme.radiusXS)
                    .strokeBorder(rarity.outline.opacity(0.6), lineWidth: 1)
            }
    }

    /// Lock square over the faceless chibi for locked characters.
    private var lockBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NQTheme.radiusS)
                .fill(NQTheme.inkFaint)
                .frame(width: 26, height: 26)
            NQIcon.lock.view
                .frame(width: 14, height: 14)
                .foregroundStyle(.white)
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
