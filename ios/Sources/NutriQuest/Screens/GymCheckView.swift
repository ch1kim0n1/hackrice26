import SwiftUI
import UIKit
import NutriQuestUI

enum GymCheckStage { case capture, verifying, verified }

struct GymCheckView: View {
    var stage: GymCheckStage

    @State private var localStage: GymCheckStage?
    @State private var capturedImage: UIImage?
    @State private var showCamera = false
    @State private var celebrateTrigger = 0
    @Environment(\.nqAccent) private var accent
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var gameState: GameState

    private var currentStage: GymCheckStage { localStage ?? stage }

    var body: some View {
        VStack(spacing: NQTheme.spaceXL - 8) {
            switch currentStage {
            case .capture: captureBody
            case .verifying: verifyingBody
            case .verified: verifiedBody
            }
        }
        .padding(NQTheme.spaceL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nqSceneBackground(GameArt.scene("gym"))
        .navigationTitle("Gym Check")
        .navigationBarTitleDisplayMode(.inline)
        .animation(NQMotion.springy, value: currentStage)
        .nqSuccessBurst(on: celebrateTrigger)
        .fullScreenCover(isPresented: $showCamera) {
            MealPhotoCapture(
                onCapture: handlePhoto,
                onCancel: { showCamera = false }
            )
            .ignoresSafeArea()
        }
    }

    private var captureBody: some View {
        VStack(spacing: NQTheme.spaceL - 2) {
            viewfinder
            VStack(alignment: .leading, spacing: NQTheme.spaceS + 2) {
                checklistRow("At a gym or workout space")
                checklistRow("Equipment or workout gear visible")
                checklistRow("Good lighting so the space is visible")
            }
            .frame(maxWidth: 280)
            NQButton("Take Photo", icon: .sparkle) {
                showCamera = true
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func handlePhoto(_ image: UIImage) {
        showCamera = false
        capturedImage = image
        localStage = .verifying
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            localStage = .verified
            gameState.logGymCheck()
            celebrateTrigger += 1
            NQJuice.success()
        }
    }

    private func checklistRow(_ text: String) -> some View {
        HStack(spacing: NQTheme.spaceS) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: NQText.body.size, weight: .semibold))
                .foregroundStyle(accent.accent)
            Text(text)
                .font(NQText.caption.font)
                .foregroundStyle(NQTheme.inkSubtle)
        }
        .accessibilityElement(children: .combine)
    }

    private var verifyingBody: some View {
        VStack(spacing: NQTheme.spaceL) {
            photoStage(beam: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Logging your gym photo")

            VStack(spacing: NQTheme.spaceS) {
                NQDotsLoader(color: accent.accentDark)
                Text("Logging today's gym check…")
                    .font(NQText.body.font)
                    .foregroundStyle(NQTheme.inkMuted)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var verifiedBody: some View {
        VStack(spacing: NQTheme.spaceL) {
            photoStage(beam: false)
            Text("Gym check logged")
                .font(NQText.displayL.font)
                .foregroundStyle(NQTheme.ink)
                .multilineTextAlignment(.center)

            HStack(spacing: NQTheme.spaceM) {
                RoundedRectangle(cornerRadius: NQTheme.radiusM)
                    .fill(accent.accentSoft)
                    .frame(width: 44, height: 44)
                    .overlay {
                        NQAssetImage("nutriquest-strength-bolt-512")
                            .frame(width: 22, height: 22)
                            .colorMultiply(accent.accentDark)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Training buff unlocked")
                        .font(NQText.bodyL.font.weight(.heavy))
                        .foregroundStyle(NQTheme.ink)
                    Text("+5% daily multiplier for 24 hours")
                        .font(NQText.captionS.font)
                        .foregroundStyle(NQTheme.inkMuted)
                }
                .accessibilityElement(children: .combine)
            }
            .nqPadding(.card)
            .frame(maxWidth: .infinity)
            .nqPlate(RoundedRectangle(cornerRadius: NQTheme.radiusL), elevation: .card)

            NQButton("Nice!") { dismiss() }
        }
        .frame(maxWidth: .infinity)
        .transition(NQTransition.summon)
    }

    @ViewBuilder private func photoStage(beam: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: NQTheme.radiusXL + 8)
                .fill(
                    LinearGradient(colors: [NQTheme.chrome, NQTheme.inkDeep], startPoint: .top, endPoint: .bottom)
                )
                .frame(height: 260)
                .nqElevation(.raised)
            if let capturedImage {
                Image(uiImage: capturedImage)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusXL + 8))
            } else {
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 46))
                    .foregroundColor(.white.opacity(0.85))
            }
            if beam {
                NQScanBeam(beamColor: accent.accent)
                    .clipShape(RoundedRectangle(cornerRadius: NQTheme.radiusXL + 8))
            }
        }
    }

    private var viewfinder: some View {
        photoStage(beam: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Workout photo preview area")
    }
}
