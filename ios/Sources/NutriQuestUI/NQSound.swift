import AudioToolbox
import AVFAudio
import Foundation

/// User-facing feedback preferences, persisted in UserDefaults. Both default
/// to on; the Profile screen exposes toggles. Every NQSound/NQHaptic entry
/// point checks these so one setting silences the whole app.
public enum NQFeedbackSettings {
    public static let soundKey = "settings.sound.enabled"
    public static let hapticsKey = "settings.haptics.enabled"

    public static var soundEnabled: Bool {
        UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true
    }
    public static var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true
    }
    public static func setSound(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: soundKey)
    }
    public static func setHaptics(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: hapticsKey)
    }
}

/// Sound design layer — completes the sensory stack (haptic + visual + audio).
/// Bundled Kenney CC0 clips (.caf) in Resources/Audio, resolved via
/// Bundle.module; every effect keeps a system-sound fallback so a missing
/// file degrades silently instead of muting feedback. All plays are
/// fire-and-forget.
public enum NQSound {

    public enum Effect: String, CaseIterable {
        case tap = "ui-tap"
        case tapAlt = "ui-tap-alt"
        case toggle = "ui-toggle"
        case hover = "ui-hover"
        case success = "victory-jingle"
        case victory = "victory-jingle-alt"
        case reveal = "summon-fanfare"
        case revealAlt = "summon-fanfare-alt"
        case unlock = "crate-latch"
        case hit = "battle-hit"
        case hitLight = "battle-hit-light"
        case hitHeavy = "battle-hit-heavy"
        case crit = "battle-crit"
        case crateOpen = "crate-open"
        case crateReveal = "crate-reveal"
        case crateRumble = "crate-rumble-loop"
        case crateRoll = "crate-roll"
        case crateCreak = "crate-creak"
        case keys = "keys-earn"
        case coins = "reward-coins"
        /// Wager lost. There's no dedicated "bust" clip in the bundled set —
        /// reuses the low creak, which reads as an anticlimax without
        /// borrowing a positive cue (crate-open, victory, etc.) for a loss.
        case bust
        case error

        /// Bundled clip name, if one exists for this effect.
        var fileName: String? {
            switch self {
            case .error: return nil
            case .bust: return "crate-creak"
            default: return rawValue
            }
        }

        /// System sound used when the bundled clip is missing.
        var fallbackID: SystemSoundID {
            switch self {
            case .success, .victory: return SystemSoundID(1025)
            case .reveal: return SystemSoundID(1335)
            case .error: return SystemSoundID(1073)
            case .unlock, .crateOpen, .crateReveal, .keys, .coins: return SystemSoundID(1103)
            default: return SystemSoundID(1104)
            }
        }
    }

    /// One player per effect, reused — replays restart the clip instantly.
    private static var players: [Effect: AVAudioPlayer] = [:]

    /// Plays once. Call from the main thread (every call site is UI-driven).
    public static func play(_ effect: Effect) {
        guard NQFeedbackSettings.soundEnabled else { return }
        guard let player = player(for: effect) else {
            AudioServicesPlaySystemSound(effect.fallbackID)
            return
        }
        player.numberOfLoops = 0
        if player.isPlaying { player.currentTime = 0 }
        player.play()
    }

    /// Loops a clip until `stopLoop` — used for the crate shake build-up.
    public static func startLoop(_ effect: Effect) {
        guard NQFeedbackSettings.soundEnabled else { return }
        guard let player = player(for: effect) else { return }
        player.numberOfLoops = -1
        player.play()
    }

    public static func stopLoop(_ effect: Effect) {
        players[effect]?.stop()
        players[effect]?.currentTime = 0
    }

    private static func player(for effect: Effect) -> AVAudioPlayer? {
        if let existing = players[effect] { return existing }
        guard let name = effect.fileName,
              let url = Bundle.module.url(forResource: name, withExtension: "caf")
                ?? Bundle.main.url(forResource: name, withExtension: "caf"),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        players[effect] = player
        return player
    }
}

/// One call = the full juice stack: haptic + sound together, overlapping.
/// Use this instead of calling NQHaptic/NQSound separately so feedback stays
/// consistent across the app.
public enum NQJuice {
    public static func tap() {
        NQHaptic.light()
        NQSound.play(.tap)
    }

    public static func success() {
        NQHaptic.success()
        NQSound.play(.success)
    }

    public static func reveal() {
        NQHaptic.medium()
        NQSound.play(.reveal)
    }

    public static func error() {
        NQHaptic.error()
        NQSound.play(.error)
    }

    public static func unlock() {
        NQHaptic.medium()
        NQSound.play(.unlock)
    }

    public static func hit(heavy: Bool = false) {
        if heavy { NQHaptic.medium() } else { NQHaptic.light() }
        NQSound.play(heavy ? .hitHeavy : .hit)
    }

    public static func crit() {
        NQHaptic.medium()
        NQSound.play(.crit)
    }

    public static func keys() {
        NQHaptic.light()
        NQSound.play(.keys)
    }

    /// The one call site every casino game (cauldron, mines, plinko, portal
    /// wheel) should use to resolve a wager — a loss isn't an app error, so
    /// it gets its own cue instead of borrowing `.error()`'s system beep.
    public static func wagerResult(won: Bool) {
        if won {
            NQHaptic.success()
            NQSound.play(.coins)
            NQSound.play(.victory)
        } else {
            NQHaptic.warning()
            NQSound.play(.bust)
        }
    }
}
