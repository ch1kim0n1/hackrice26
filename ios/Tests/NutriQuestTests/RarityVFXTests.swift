import XCTest
import SwiftUI
@testable import NutriQuest

final class RarityVFXTests: XCTestCase {
    func testRarityHierarchyAndStationaryLowerTiers() {
        for rarity in [Rarity.common, .uncommon, .rare] {
            let value = RarityAnimationConfiguration.configuration(for: rarity)
            XCTAssertFalse(value.floatEnabled)
            XCTAssertFalse(value.auraEnabled)
            XCTAssertFalse(value.particlesEnabled)
            XCTAssertEqual(value.horizontalDrift, 0)
        }
        for rarity in [Rarity.common, .uncommon] {
            XCTAssertFalse(RarityAnimationConfiguration.configuration(for: rarity).hasEffects)
        }
        let rare = RarityAnimationConfiguration.configuration(for: .rare)
        XCTAssertTrue(rare.glowEnabled)
        XCTAssertEqual(rare.glowOpacity, 0.30...0.50)
        XCTAssertEqual(rare.glowColor, Rarity.rare.ringColor)
        let tiers: [Rarity] = [.epic, .legendary, .mythic, .secret]
        XCTAssertEqual(tiers.map { RarityAnimationConfiguration.configuration(for: $0).aura },
                       [.epic, .gold, .red, .smoke])
        for rarity in tiers {
            let value = RarityAnimationConfiguration.configuration(for: rarity)
            XCTAssertTrue(value.auraEnabled)
            XCTAssertTrue(value.floatEnabled)
            XCTAssertTrue(value.glowEnabled)
            XCTAssertTrue((12...24).contains(value.auraFPS))
            XCTAssertLessThanOrEqual(value.particleCount, 8)
        }
        let sizes = tiers.map { RarityAnimationConfiguration.configuration(for: $0).auraScale }
        XCTAssertEqual(sizes, sizes.sorted())
        XCTAssertEqual(RarityAnimationConfiguration.configuration(for: .mythic).secondaryAura, .flame)
    }

    func testUnknownBackendRarityIsNonanimatedWithoutChangingModelDecoding() {
        for raw in ["future-tier", "", "MYTHIC", "unknown"] {
            let value = RarityAnimationConfiguration.configuration(backendValue: raw)
            XCTAssertFalse(value.hasEffects)
            XCTAssertFalse(value.floatEnabled)
            XCTAssertFalse(value.particlesEnabled)
        }
        XCTAssertEqual(RarityAnimationConfiguration.configuration(backendValue: "epic").aura, .epic)
    }

    func testSecretReversesSmokeAndParticlesActuallyConverge() {
        let secret = RarityAnimationConfiguration.configuration(for: .secret)
        XCTAssertEqual(secret.aura, .smoke)
        XCTAssertTrue(secret.playsInReverse)
        XCTAssertEqual(secret.particleStyle, .inward)
        XCTAssertEqual(secret.horizontalDrift, 1)
        for index in 0..<secret.particleCount {
            let radii = [0.0, 0.25, 0.5, 0.75, 1.0].map { progress in
                let p = RarityVFXMotion.particlePosition(index: index, progress: progress, style: .inward)
                return hypot(p.x - 0.5, p.y - 0.5)
            }
            XCTAssertEqual(radii, radii.sorted(by: >))
            XCTAssertLessThan(radii.last!, radii.first! / 4)
        }
    }

    func testOrderedManifestAndFramePlaybackBoundaries() {
        XCTAssertEqual(RarityVFXAssetManifest.Sequence.smoke.orderedNames.first, "smoke_000")
        XCTAssertEqual(RarityVFXAssetManifest.Sequence.smoke.orderedNames.last, "smoke_029")
        for sequence in RarityVFXAssetManifest.Sequence.allCases {
            XCTAssertEqual(sequence.orderedNames, sequence.orderedNames.sorted())
            XCTAssertEqual(Set(sequence.orderedNames).count, sequence.frameCount)
        }
        XCTAssertEqual(RarityVFXAssetManifest.frameIndex(time: 1.25, fps: 16, count: 20, reversed: false), 0)
        XCTAssertEqual(RarityVFXAssetManifest.frameIndex(time: 0, fps: 15, count: 30, reversed: true), 29)
        XCTAssertEqual(RarityVFXAssetManifest.frameIndex(time: 1.0 / 15, fps: 15, count: 30, reversed: true), 28)
        XCTAssertNil(RarityVFXAssetManifest.frameIndex(time: 0, fps: 15, count: 0, reversed: false))
        XCTAssertNil(RarityVFXAssetManifest.frameIndex(time: .nan, fps: 15, count: 30, reversed: false))
    }

    func testEveryProductionFrameIsBundledAndDecodesWithAlpha() async {
        var total = 0
        for sequence in RarityVFXAssetManifest.Sequence.allCases {
            let frames = await RarityFrameCache.shared.frames(for: sequence)
            XCTAssertEqual(frames.images.count, sequence.frameCount, sequence.rawValue)
            for image in frames.images {
                XCTAssertLessThanOrEqual(image.size.width, 256)
                XCTAssertLessThanOrEqual(image.size.height, 256)
                XCTAssertNotEqual(image.cgImage?.alphaInfo, CGImageAlphaInfo.none)
            }
            total += frames.decodedBytes
        }
        XCTAssertLessThan(total, 32 * 1024 * 1024)
    }

    func testMissingAndCorruptAssetsFailSafely() {
        XCTAssertNil(RarityVFXAssetManifest.url(for: "not-a-frame", sequence: .epic))
        XCTAssertNil(RarityFrameCache.decode(url: URL(fileURLWithPath: "/does-not-exist.png")))
        let empty = RarityFrames(images: [])
        XCTAssertEqual(empty.decodedBytes, 0)
    }

    func testSharedCacheReusesDecodeAndCanPurge() async {
        let cache = RarityFrameCache()
        async let a = cache.frames(for: .epic)
        async let b = cache.frames(for: .epic)
        let (first, second) = await (a, b)
        XCTAssertTrue(first === second)
        let count = await cache.decodeCount
        XCTAssertEqual(count, 1)
        await cache.removeAll()
        let third = await cache.frames(for: .epic)
        XCTAssertFalse(first === third)
        let afterPurge = await cache.decodeCount
        XCTAssertEqual(afterPurge, 2)
    }

    func testAccentsAreInfrequentAndDoNotFireOnAppearance() {
        for rarity in [Rarity.legendary, .mythic, .secret] {
            let config = RarityAnimationConfiguration.configuration(for: rarity)
            XCTAssertEqual(RarityVFXMotion.accent(0, configuration: config), 0)
            XCTAssertLessThan(config.accentDuration / config.accentInterval, 0.2)
            XCTAssertGreaterThan(RarityVFXMotion.accent(config.accentInterval - config.accentDuration / 2,
                                                      configuration: config), 0)
        }
    }

    @MainActor
    func testLowerTiersAndDisabledWrapperPreserveExactImageLayoutAndPixels() {
        let artwork = Image(systemName: "leaf.fill").resizable().scaledToFit()
            .frame(width: 96, height: 124)
        let original = ImageRenderer(content: artwork).uiImage
        for rarity in Rarity.allCases {
            let wrapper = MonsterRarityPresentationView(rarity: rarity, enabled: false) { artwork }
            let result = ImageRenderer(content: wrapper).uiImage
            XCTAssertEqual(result?.size, CGSize(width: 96, height: 124))
            XCTAssertEqual(result?.pngData(), original?.pngData(), rarity.rawValue)
        }
        for rarity in [Rarity.common, .uncommon] {
            let result = ImageRenderer(content: MonsterRarityPresentationView(rarity: rarity) { artwork }).uiImage
            XCTAssertEqual(result?.pngData(), original?.pngData())
        }
    }

    @MainActor
    func testStaticAuraIgnoresPlaybackTime() async {
        for rarity in [Rarity.epic, .legendary, .mythic, .secret] {
            let config = RarityAnimationConfiguration.configuration(for: rarity)
            let frames = await RarityFrameCache.shared.frames(for: config.aura!)
            func render(_ time: Double) -> Data? {
                ImageRenderer(content: AuraFrameAnimationView(frames: frames, time: time,
                    configuration: config, isStatic: true).frame(width: 96, height: 124)).uiImage?.pngData()
            }
            XCTAssertNotNil(render(0))
            XCTAssertEqual(render(0), render(12.75), rarity.rawValue)
        }
    }
}
