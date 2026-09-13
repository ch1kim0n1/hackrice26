import SwiftUI

/// Soft, chunky sticker corners shared by menus and controls.
public struct NQPanelShape: InsettableShape {
    private var cut: CGFloat
    private var inset: CGFloat = 0

    public init(cut: CGFloat = NQTheme.radiusS) { self.cut = cut }

    public func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = max(0, cut * 1.65 - inset)
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: r)
    }

    public func inset(by amount: CGFloat) -> NQPanelShape {
        var copy = self
        copy.inset += amount
        return copy
    }
}
