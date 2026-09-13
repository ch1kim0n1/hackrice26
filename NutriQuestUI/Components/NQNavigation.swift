import SwiftUI

/// App tabs, in bottom-nav order.
public enum NQTab: String, CaseIterable, Sendable {
    case home
    case collection
    case scan
    case battle
    case profile

    public var title: String {
        switch self {
        case .home: return "Home"
        case .collection: return "Squad"
        case .scan: return "Scan"
        case .battle: return "Battle"
        case .profile: return "Profile"
        }
    }

    public var icon: NQIcon {
        switch self {
        case .home: return .home
        case .collection: return .grid
        case .scan: return .scan
        case .battle: return .battle
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

    public init() where Trailing == EmptyView {}

    public var body: some View {
        HStack {
            HStack(spacing: NQTheme.spaceS) {
                NQLogoMark()
                Text("NutriQuest")
                    .font(NQText.display.font)
                    .foregroundStyle(NQTheme.ink)
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
            Circle()
                .fill(accent.accent)
            NQIcon.checkCircle.view
                .frame(width: 13, height: 13)
                .foregroundStyle(accent.accent.readableTextColor())
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }
}

// MARK: - Bottom navigation

/// Five-tab bottom nav with an oversized center scan button.
public struct NQBottomNav: View {
    @Binding private var selection: NQTab

    @Environment(\.nqAccent) private var accent

    public init(selection: Binding<NQTab>) {
        _selection = selection
    }

    public var body: some View {
        HStack {
            navItem(.home)
            navItem(.collection)
            scanButton
            navItem(.battle)
            navItem(.profile)
        }
        .nqPadding(.nav)
        .background(NQTheme.background)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: NQTheme.radiusXL, topTrailingRadius: NQTheme.radiusXL))
        .nqElevation(.nav)
        .ignoresSafeArea(.keyboard)
    }

    private func navItem(_ tab: NQTab) -> some View {
        Button {
            selection = tab
        } label: {
            VStack(spacing: 3) {
                NQTabIcon(icon: tab.icon, selected: selection == tab)
                Text(tab.title)
                    .font(NQText.caption.font)
            }
            .foregroundStyle(selection == tab ? accent.accentDark : NQTheme.inkFaint)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }

    private var scanButton: some View {
        Button {
            NQHaptic.medium()
            selection = .scan
        } label: {
            ZStack {
                Circle()
                    .fill(accent.accent)
                    .frame(width: 54, height: 54)
                    .nqElevation(.glow(accent.accent))
                NQIcon.scan.view
                    .frame(width: 24, height: 24)
                    .foregroundStyle(accent.accent.readableTextColor())
            }
        }
        .buttonStyle(NQPressableStyle(scale: 0.88))
        .offset(y: -14)
        .accessibilityLabel(NQTab.scan.title)
        .accessibilityAddTraits(selection == .scan ? .isSelected : [])
    }
}

// MARK: - Screen scaffold

/// Full screen scaffold: accent-tinted background, decorative blobs and
/// sparkles, top bar, content, bottom nav.
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
            accent.accentBg.ignoresSafeArea()

            // Decorative blobs (fixed composition, accent-tinted)
            Circle()
                .fill(accent.accentSoft)
                .frame(width: 220, height: 220)
                .offset(x: 110, y: -190)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Circle()
                .fill(accent.accentSoft)
                .frame(width: 190, height: 190)
                .opacity(0.7)
                .offset(x: -150, y: -60)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            NQFloatingSparkles(count: 5, color: accent.accentDark)
                .accessibilityHidden(true)

            VStack(spacing: 0) {
                if !hidesNav {
                    NQTopBar(trailing: { trailing })
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                NQBottomNav(selection: $tab)
                    .ignoresSafeArea(.keyboard)
            }
        }
    }
}
