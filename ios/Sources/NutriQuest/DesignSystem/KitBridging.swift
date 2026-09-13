import SwiftUI
import NutriQuestUI
import BattleKit

extension Character {
    /// The character's identity color as the kit's palette type.
    var kitColor: NQCharacterColor {
        NQCharacterColor(name: name, base: Color(hex: colorHex))
    }
}

extension StatType {
    /// The kit's stat-type enum (badge icons, display names).
    var kitStatType: NQStatType {
        NQStatType(rawValue: rawValue) ?? .fiber
    }
}

extension Rarity {
    /// The kit's rarity enum (card rings, chips).
    var kitRarity: NQRarity {
        NQRarity(rawValue: rawValue) ?? .common
    }

    /// 1:1 by case name — both ladders carry the same seven tiers. Collapsing
    /// uncommon/mythic/secret here would make a Mythic fight as a Legendary,
    /// the exact mismatch the unified ladder exists to remove.
    var battleRarity: BattleRarity {
        switch self {
        case .common: return .common
        case .uncommon: return .uncommon
        case .rare: return .rare
        case .epic: return .epic
        case .legendary: return .legendary
        case .mythic: return .mythic
        case .secret: return .secret
        }
    }
}

extension BattleRarity {
    /// The inverse of `Rarity.battleRarity`. Case by case, because the two
    /// enums have different raw types (Int vs String): bridging through the
    /// raw value produced "0"/"1"/…, which never parses, and silently made
    /// every scanned character common.
    var appRarity: Rarity {
        switch self {
        case .common: return .common
        case .uncommon: return .uncommon
        case .rare: return .rare
        case .epic: return .epic
        case .legendary: return .legendary
        case .mythic: return .mythic
        case .secret: return .secret
        }
    }
}

/// The bundle carrying `Sources/NutriQuest/Resources`. Under SwiftPM (the
/// `NutriQuest` library target, and Xcode's "open Package.swift and run")
/// resources compile into the synthesized `Bundle.module` — `SWIFT_PACKAGE`
/// is defined only in that build context. The CI-buildable app target
/// (issue #25) compiles these sources directly into the app, where Xcode
/// bundles Resources into the main bundle instead — `Bundle.module` doesn't
/// exist there at all (a compile error, not a runtime miss), so this must
/// be resolved at compile time, not with a runtime fallback.
#if SWIFT_PACKAGE
private let artworkBundle = Bundle.module
#else
private let artworkBundle = Bundle.main
#endif

/// A character's illustration: bundled hand-drawn asset first, then
/// server-generated anime art (with the procedural chibi as the loading and
/// offline fallback). Shared by Home, Battle, Collection, and Profile.
///
/// The asset must be looked up in `artworkBundle`, not the main bundle by
/// default — see its doc comment. A bare `Image(assetName)` renders blank
/// under SwiftPM because it only searches the main bundle (issue #26).
struct CharacterArtwork: View {
    let character: Character
    /// Facial expression for the procedural chibi fallback. Ignored when a
    /// hand-drawn asset or generated art resolves (static art).
    var expression: ChibiExpression = .happy
    /// Battle KO / hit pose when a hurt sprite exists.
    var hurt: Bool = false

    var body: some View {
        let cartoon = GameArt.sprite(id: character.baseID, hurt: hurt)
        if character.isLocked, let image = NQAsset.uiImage("unknown-characters") {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        } else if let image = NQAsset.uiImage(cartoon) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        } else if let assetName = character.artworkAssetName,
           UIImage(named: assetName, in: artworkBundle, compatibleWith: nil) != nil {
            Image(assetName, bundle: artworkBundle)
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        } else if let url = character.artworkRemoteURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        // Slight zoom hides the service watermark strip.
                        .scaleEffect(1.18)
                        .clipped()
                default:
                    ChibiCharacterView(color: character.kitColor, statType: character.statType.kitStatType, expression: expression)
                }
            }
            .accessibilityHidden(true)
        } else {
            // No hand-drawn asset: build the creature procedurally. A dish
            // character carries a food group, which shapes its build and adds
            // a motif so a salad and a steak aren't the same silhouette in
            // two colours. Barcode/sample characters pass nil and render
            // exactly as before.
            ChibiCharacterView(
                color: character.kitColor,
                statType: character.statType.kitStatType,
                expression: expression,
                pose: ChibiPose.forFoodGroup(character.foodGroup, name: character.name),
                motif: ChibiMotif.forFoodGroup(character.foodGroup)
            )
        }
    }
}
