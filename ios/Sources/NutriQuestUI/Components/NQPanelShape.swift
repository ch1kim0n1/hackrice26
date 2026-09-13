import SwiftUI

/// Soft, chunky sticker corners shared by menus and controls.
public struct NQPanelShape: InsettableShape {
    private var cut: CGFloat
    private var inset: CGFloat = 0

    public init(cut: CGFloat = NQTheme.radiusS) { self.cut = cut }

    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        // Cap to 18% of the short side so a 28pt-tall control can never
        // round into a capsule the way `cut * 1.65` used to.
        let wanted = max(0, cut - inset)
        let radius = min(wanted, min(r.width, r.height) * 0.18)
        return RoundedRectangle(cornerRadius: radius, style: .circular).path(in: r)
    }

    public func inset(by amount: CGFloat) -> NQPanelShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// 5pt ticket corners. Use this for HUD chrome so a short label can never
/// become a pill, regardless of how wide or tall the control is.
public struct NQTicketShape: InsettableShape {
    private var inset: CGFloat = 0

    public init() {}

    public func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: 5, style: .circular)
            .path(in: rect.insetBy(dx: inset, dy: inset))
    }

    public func inset(by amount: CGFloat) -> NQTicketShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}
