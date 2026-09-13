import SwiftUI

/// App tabs, in bottom-nav order.
public enum NQTab: String, CaseIterable, Sendable {
    case home
    case collection
    case scan
    /// The Monster Casino: where characters are wagered rather than fought.
    /// Fighting still lives one tap inside it (see CasinoHubView).
    case casino
    case profile

    public var title: String {
        switch self {
        case .home: return "Home"
        case .collection: return "Squad"
        case .scan: return "Scan"
        case .casino: return "Casino"
        case .profile: return "Profile"
        }
    }

    public var icon: NQIcon {
        switch self {
        case .home: return .home
        case .collection: return .grid
        case .scan: return .scan
        case .casino: return .cauldron
        case .profile: return .person
        }
    }
}

// MARK: - Top bar

/// App top bar: logo + wordmark on the left, trailing slot (streak pill etc.).
public struct NQTopBar<Trailing: View>: View {
    private let trailing: Trailing

    public init(@ViewBuilder trailing: () -> Trailing) {
        self.trailing = trailing()
    }

    public init() where Trailing == EmptyView {
        self.trailing = EmptyView()
    }

    public var body: some View {
        HStack {
            HStack(spacing: NQTheme.spaceS) {
                NQLogoMark()
                Text("NutriQuest")
                    .font(NQText.display.font)
                    .foregroundStyle(NQTheme.gold)
                    .shadow(color: NQTheme.inkDeep, radius: 0, y: 2)
            }
            Spacer()
            trailing
        }
        .padding(.top, NQTheme.spaceL + 2)
        .nqPadding(.screen)
    }
}

/// Circular checkmark logo mark, tinted with the accent.
public struct NQLogoMark: View {
    @Environment(\.nqAccent) private var accent

    public init() {}

    public var body: some View {
        ZStack {
            if let image = NQAsset.uiImage("transparent-logo") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Circle()
                    .fill(accent.accent)
                NQIcon.checkCircle.view
                    .frame(width: NQLayout.iconXS, height: NQLayout.iconXS)
                    .foregroundStyle(accent.accent.readableTextColor())
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }
}

// MARK: - Bottom navigation

/// Framed command dock with a raised central scan crest.
public struct NQBottomNav: View {
    @Binding private var selection: NQTab
    private var inviteScan: Bool

    @Environment(\.nqAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scanHop = false

    public init(selection: Binding<NQTab>, inviteScan: Bool = false) {
        _selection = selection
        self.inviteScan = inviteScan
    }

    public var body: some View {
        HStack {
            navItem(.home)
            navItem(.collection)
            scanButton
            navItem(.casino)
            navItem(.profile)
        }
        .nqPadding(.nav)
        .padding(.horizontal, NQTheme.spaceS)
        .nqPlate(NQPanelShape(cut: NQTheme.radiusM), fill: NQTheme.background,
                 elevation: .nav, inkStroke: true, lineWidth: 2)
        .overlay(alignment: .top) {
            Rectangle().fill(NQTheme.gold.opacity(0.7))
                .frame(width: 48, height: 2)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, NQTheme.spaceL)
        .padding(.bottom, NQTheme.spaceS)
        .ignoresSafeArea(.keyboard)
    }

    private func navItem(_ tab: NQTab) -> some View {
        let isSelected = selection == tab
        return Button {
            NQSound.play(.tapAlt)
            withAnimation(NQMotion.snappy) { selection = tab }
        } label: {
            VStack(spacing: 2) {
                NQTabIcon(icon: tab.icon, selected: isSelected)
                    .frame(height: 30)
                Text(tab.title)
                    .font(NQText.captionS.font.weight(isSelected ? .heavy : .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? accent.accent : NQTheme.inkFaint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: NQLayout.controlMinHeight)
            .background {
                if isSelected {
                    NQPanelShape(cut: NQTheme.radiusXS).fill(accent.accent.opacity(0.1))
                        .overlay { NQPanelShape(cut: NQTheme.radiusXS).strokeBorder(accent.accent.opacity(0.35), lineWidth: 1) }
                }
            }
            .animation(NQMotion.snappy, value: isSelected)
        }
        .buttonStyle(NQPressableStyle(scale: 0.92, haptic: false, ledge: 2))
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var scanButton: some View {
        let isSelected = selection == .scan
        return Button {
            NQJuice.tap()
            withAnimation(NQMotion.snappy) { selection = .scan }
        } label: {
            VStack(spacing: NQTheme.spaceXS) {
                ZStack {
                    NQPanelShape(cut: NQTheme.radiusM)
                        .fill(LinearGradient(colors: [accent.accentDark, NQTheme.accentPress],
                                             startPoint: .top, endPoint: .bottom))
                    NQPanelShape(cut: NQTheme.radiusM)
                        .strokeBorder(NQTheme.inkDeep, lineWidth: 2)
                    NQIconView(icon: .scan, tint: NQTheme.inkDeep)
                        .frame(width: 28, height: 28)
                }
                .frame(width: 56, height: 50)
                .shadow(color: NQTheme.inkDeep, radius: 0, y: isSelected ? 1 : 4)
                Text(NQTab.scan.title)
                    .font(NQText.captionS.font.weight(.heavy))
                    .foregroundStyle(accent.accent)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: NQLayout.controlMinHeight)
            .offset(y: inviteScan && !isSelected && scanHop && !reduceMotion ? -10 : -6)
            .animation(NQMotion.snappy, value: isSelected)
        }
        .buttonStyle(NQPressableStyle(scale: 0.9, haptic: false, ledge: 4))
        .onAppear {
            guard inviteScan, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                scanHop = true
            }
        }
        .accessibilityLabel(NQTab.scan.title)
        .accessibilityHint(inviteScan && !isSelected ? "Scan a snack to summon a monster" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Transparent nav bar over scene art so pushed screens and tab roots share
/// one cartoon world instead of a grey UIKit strip.
public struct NQTransparentNav: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

public extension View {
    func nqTransparentNav() -> some View {
        modifier(NQTransparentNav())
    }
}

// MARK: - Screen scaffold

/// Full screen scaffold: accent-tinted background, decorative blobs,
/// top bar, content, bottom nav.
public struct NQScreen<Content: View, Trailing: View>: View {
    private let content: Content
    private let trailing: Trailing
    private var hidesNav: Bool = false

    @Binding private var tab: NQTab
    @Environment(\.nqAccent) private var accent

    public init(
        tab: Binding<NQTab>,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        _tab = tab
        self.trailing = trailing()
        self.content = content()
    }

    public init(tab: Binding<NQTab>, @ViewBuilder content: () -> Content) where Trailing == EmptyView {
        _tab = tab
        self.trailing = EmptyView()
        self.content = content()
    }

    public var body: some View {
        ZStack {
            NQAdventureBackdrop().ignoresSafeArea()

            VStack(spacing: 0) {
                if !hidesNav {
                    NQTopBar(trailing: { trailing })
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Bottom inset (not a VStack sibling) so the accent background
        // extends underneath the floating nav to the screen edge.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NQBottomNav(selection: $tab)
                .ignoresSafeArea(.keyboard)
        }
    }
}
