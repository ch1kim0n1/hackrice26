import SwiftUI
import UIKit

/// Loose PNGs from `game-assets/`, bundled as a folder resource on the app
/// target. Looks in the app bundle first, then this module, so SwiftUI
/// previews and the shipped app both resolve the same names.
public enum NQAsset {
    public static func uiImage(_ name: String) -> UIImage? {
        let bundles: [Bundle] = {
            #if SWIFT_PACKAGE
            return [Bundle.main, Bundle.module]
            #else
            return [Bundle.main]
            #endif
        }()
        for bundle in bundles {
            let subs: [String?] = [
                "game-assets",
                "game-assets/brainrot",
                "GameAssets",
                "GameAssets/brainrot",
                nil
            ]
            for sub in subs {
                for ext in ["png", "webp"] {
                    let url = sub == nil
                        ? bundle.url(forResource: name, withExtension: ext)
                        : bundle.url(forResource: name, withExtension: ext, subdirectory: sub)
                    if let url, let image = UIImage(contentsOfFile: url.path) {
                        return image
                    }
                }
            }
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil) {
                return image
            }
        }
        return nil
    }
}

/// Cartoon PNG, scaled to fit. Renders nothing if the file is missing so a
/// bad name never punches a hole in layout.
public struct NQAssetImage: View {
    private let name: String

    public init(_ name: String) {
        self.name = name
    }

    public var body: some View {
        if let image = NQAsset.uiImage(name) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        }
    }
}

/// Full-bleed cartoon banner. Crops to `height` so a wide painting fills the card.
public struct NQAssetBanner: View {
    private let name: String
    private let height: CGFloat

    public init(_ name: String, height: CGFloat = 128) {
        self.name = name
        self.height = height
    }

    public var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                if let image = NQAsset.uiImage(name) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .clipShape(NQPanelShape(cut: NQTheme.radiusL))
            .overlay {
                NQPanelShape(cut: NQTheme.radiusL)
                    .strokeBorder(NQTheme.inkDeep, lineWidth: 3)
            }
            .nqElevation(.sticker)
            .accessibilityHidden(true)
    }
}

public extension View {
    /// Full-bleed scene painting with a wash so cards and type stay readable.
    func nqSceneBackground(_ name: String, wash: Double = 0.64) -> some View {
        background {
            GeometryReader { geo in
                ZStack {
                    if let image = NQAsset.uiImage(name) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    }
                    NQTheme.page.opacity(wash)
                }
            }
            .ignoresSafeArea()
        }
    }
}
