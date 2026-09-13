#if DEBUG
import SwiftUI
import NutriQuestUI

/// Presented only by an explicit debug launch flag; never adds production controls.
struct RarityAuraDemoView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var options = RarityVFXPreviewOptions()
    @State private var lightBackground = ProcessInfo.processInfo.arguments.contains("-rarityVFXLight")
    @State private var stress = ProcessInfo.processInfo.arguments.contains("-rarityVFXStress")
    @State private var staticPreview = ProcessInfo.processInfo.arguments.contains("-rarityVFXStatic")
    @State private var showControls = false

    private enum Layout {
        static let imageWidth: CGFloat = 96
        static let imageHeight: CGFloat = 124
        static let cardHeight: CGFloat = 164
        static let small: CGFloat = 0.85
        static let large: CGFloat = 1.12
    }

    private var effectiveOptions: RarityVFXPreviewOptions {
        var value = options
        value.forceStatic = staticPreview
        return value
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: NQTheme.spaceM) {
                    DisclosureGroup("Preview controls", isExpanded: $showControls) { controls }
                        .foregroundStyle(lightBackground ? NQTheme.inkDeep : NQTheme.ink)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: NQTheme.spaceM) {
                        ForEach(0..<(stress ? 28 : 7), id: \.self) { index in
                            demoCard(Rarity.allCases[index % Rarity.allCases.count])
                        }
                    }
                }
                .padding(NQTheme.spaceL)
            }
            .background(lightBackground ? NQTheme.ink : NQTheme.inkDeep)
            .environment(\.rarityVFXPreview, effectiveOptions)
            .navigationTitle("Rarity Aura Demo")
            .navigationBarTitleDisplayMode(.inline)
            .tint(lightBackground ? NQTheme.inkDeep : NQTheme.ink)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Rarity Aura Demo")
                        .font(NQText.heading.font)
                        .foregroundStyle(lightBackground ? NQTheme.inkDeep : NQTheme.ink)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: NQTheme.spaceS) {
            Picker("Animation speed", selection: $options.speed) {
                Text("0.5×").tag(0.5)
                Text("1×").tag(1.0)
                Text("1.5×").tag(1.5)
            }.pickerStyle(.segmented)
            Picker("Effect scale", selection: $options.scale) {
                Text("Small").tag(Layout.small)
                Text("Normal").tag(CGFloat(1))
                Text("Large").tag(Layout.large)
            }.pickerStyle(.segmented)
            Toggle("Particles", isOn: $options.particles)
            Toggle("Character float", isOn: $options.floating)
            Toggle("Static / Reduce Motion preview", isOn: $staticPreview)
            Toggle("Light background", isOn: $lightBackground)
            Toggle("Stress grid (28 cards)", isOn: $stress)
        }
        .font(NQText.caption.font)
        .foregroundStyle(lightBackground ? NQTheme.inkDeep : NQTheme.ink)
    }

    private func demoCard(_ rarity: Rarity) -> some View {
        VStack(spacing: NQTheme.spaceS) {
            MonsterRarityPresentationView(rarity: rarity) {
                // Explicit base-art variant: all seven use the exact same PNG.
                CharacterArtwork(character: SampleData.characters[0], rarity: .common)
                    .frame(width: Layout.imageWidth, height: Layout.imageHeight)
            }
            Text(rarity.label).font(NQText.heading.font)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Layout.cardHeight)
        .foregroundStyle(lightBackground ? NQTheme.inkDeep : NQTheme.ink)
        .background((lightBackground ? Color.white : NQTheme.inkDeep.mix(with: NQTheme.ink, amount: 0.06))
            .cornerRadius(NQTheme.radiusM))
        .accessibilityElement(children: .combine)
    }
}

/// This identity modifier compiles to content alone in Release.
struct RarityAuraDemoLauncher: ViewModifier {
    @State private var show = ProcessInfo.processInfo.arguments.contains("-rarityVFXDemo")
    func body(content: Content) -> some View {
        content.sheet(isPresented: $show) { RarityAuraDemoView() }
    }
}

struct RarityAuraDemoView_Previews: PreviewProvider {
    static var previews: some View {
        RarityAuraDemoView()
        MonsterRarityPresentationView(rarity: .secret) {
            CharacterArtwork(character: SampleData.characters[0], rarity: .common)
                .frame(width: 96, height: 124)
        }
        .padding(NQTheme.spaceXL)
        .background(NQTheme.inkDeep)
        .previewDisplayName("Secret")
    }
}
#else
import SwiftUI

struct RarityAuraDemoLauncher: ViewModifier {
    func body(content: Content) -> some View { content }
}
#endif
