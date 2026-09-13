import Foundation
import BattleKit

// MARK: - LAN PvP wire protocol
//
// Casual, unranked battles between players on the same local network. There is
// no server, so the *group host* is the authority: it creates matches, collects
// commit/reveal squads, runs the (unchanged) BattleKit engine and hands both
// fighters the canonical replay.
//
// Everything on the wire is plain Codable JSON. BattleKit types aren't Codable,
// so these DTOs mirror them; they are also the trust boundary — anything
// arriving from a peer is validated before it touches the engine.

enum LANProtocolVersion {
    static let current = 1
}

/// Timeouts the host enforces. Without them a stuck match would leave two
/// players "busy" forever.
enum LANTimeouts {
    static let offerReply: TimeInterval = 30
    static let squadPick: TimeInterval = 60
    /// Longer: a bracket match can start while you're still watching your
    /// previous battle.
    static let tournamentSquadPick: TimeInterval = 90
    static let reveal: TimeInterval = 10
}

/// MultipeerConnectivity caps a session at 8 peers, host included.
enum LANLimits {
    static let maxPlayers = 8
    static let maxNameLength = 24
    static let maxPlayerIDLength = 64
}

struct LANPlayer: Codable, Equatable, Hashable {
    let id: String
    let name: String
}

// MARK: - Squads

/// One committed battle unit: what to draw (the app `Character`) plus the
/// full battle snapshot — pre-scaling bases, rarity, stars, mana and the
/// authored moves. Peers can't ask the server for a catalog entry mid-match,
/// so the wire carries everything the engine needs.
struct LANUnit: Codable, Equatable {
    let character: Character
    let rarity: String
    /// 1...5 mastery stars (Secret clamps to ★2 inside the engine).
    let star: Int
    let baseHealth: Double
    let baseAttack: Double
    /// Authored Mana pool — present only on Epic+ instances.
    let baseMana: Double?
    let moves: [BattleMoveSpec]
}

struct LANSquad: Codable, Equatable {
    /// Exactly three, in battle order. Order matters: the first living unit
    /// is the active one, and forced replacements come from the top.
    let units: [LANUnit]
}

enum LANSquadError: Error, Equatable {
    case wrongSize
    case duplicateCharacters
    case statOutOfRange
    case starOutOfRange
    case unknownRarity
    case badMoves
    case badName
    case badColor
}

extension LANSquad {
    /// Sanity bounds for a peer-supplied squad. Offline, we can't prove a
    /// player owns these characters, but we can refuse anything a real
    /// collection could never produce.
    func validate() throws {
        guard units.count == 3 else { throw LANSquadError.wrongSize }
        guard Set(units.map(\.character.id)).count == units.count else {
            throw LANSquadError.duplicateCharacters
        }
        for unit in units {
            guard unit.baseHealth.isFinite, (1...2_000).contains(unit.baseHealth),
                  unit.baseAttack.isFinite, (1...500).contains(unit.baseAttack) else {
                throw LANSquadError.statOutOfRange
            }
            if let mana = unit.baseMana, !(mana.isFinite && (0...500).contains(mana)) {
                throw LANSquadError.statOutOfRange
            }
            guard (1...5).contains(unit.star) else { throw LANSquadError.starOutOfRange }
            guard Rarity(rawValue: unit.rarity) != nil else { throw LANSquadError.unknownRarity }
            guard (1...4).contains(unit.moves.count) else { throw LANSquadError.badMoves }
            for move in unit.moves {
                let ok = move.power.isFinite && (0...15).contains(move.power)
                    && move.accuracy.isFinite && (1...100).contains(move.accuracy)
                    && move.manaCost.isFinite && (0...500).contains(move.manaCost)
                    && !move.id.isEmpty && move.id.count <= 64
                    && !move.name.isEmpty && move.name.count <= 64
                    && (move.statusChance.map { $0.isFinite && (0...100).contains($0) } ?? true)
                    && (move.duration.map { (1...10).contains($0) } ?? true)
                guard ok else { throw LANSquadError.badMoves }
            }
            let name = unit.character.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= LANLimits.maxNameLength else { throw LANSquadError.badName }
            guard unit.character.colorHex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
                throw LANSquadError.badColor
            }
        }
    }

    /// The engine-side squad snapshot. Unit ids are derived from the match,
    /// side and slot, so the host and both clients agree on them without
    /// sending a map.
    func battleSpecs(matchID: UUID, side: Int) -> [BattleUnitSpec] {
        units.enumerated().map { slot, unit in
            BattleUnitSpec(
                id: LANCrypto.unitID(matchID: matchID, side: side, slot: slot).uuidString,
                name: unit.character.name,
                baseHealth: unit.baseHealth,
                baseAttack: unit.baseAttack,
                rarity: (Rarity(rawValue: unit.rarity) ?? .common).battleRarity,
                star: unit.star,
                moves: unit.moves,
                baseMana: unit.baseMana
            )
        }
    }
}

extension LANUnit {
    /// Build a unit from one of your own characters, clamped so it always
    /// passes `validate()` (long product names, odd colours, etc.).
    init(character: Character, spec: BattleUnitSpec) {
        var display = character
        let trimmed = character.name.trimmingCharacters(in: .whitespacesAndNewlines)
        display.name = trimmed.isEmpty ? "Mystery" : String(trimmed.prefix(LANLimits.maxNameLength))
        if character.colorHex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) == nil {
            display.colorHex = "#9C978F"
        }
        let clamp: (Double, ClosedRange<Double>) -> Double = { v, r in
            min(r.upperBound, max(r.lowerBound, v.isFinite ? v : r.lowerBound))
        }

        self.character = display
        self.rarity = spec.rarity.appRarity.rawValue
        self.star = min(5, max(1, spec.star))
        self.baseHealth = clamp(spec.baseHealth, 1...2_000)
        self.baseAttack = clamp(spec.baseAttack, 1...500)
        self.baseMana = spec.baseMana.map { clamp($0, 0...500) }
        self.moves = spec.moves.isEmpty ? [strikeMove] : spec.moves
    }
}

// MARK: - Replay

/// The wire replay: the engine's own event schema (BattleEvent is Codable in
/// the exact battle-event.json shape) plus the result envelope. `UInt64`
/// seeds travel as strings — JSON numbers above 2^53 don't survive.
struct LANReplay: Codable, Equatable {
    let seed: String
    let events: [BattleEvent]
    let winnerSide: Int
    let turns: Int
    let reason: String
    let hpFractionsA: [Double]
    let hpFractionsB: [Double]
    let faintedA: [String]
    let faintedB: [String]
}

extension LANReplay {
    init(_ replay: BattleReplay) {
        self.seed = String(replay.seed)
        self.events = replay.events
        self.winnerSide = replay.winnerSide
        self.turns = replay.turns
        self.reason = replay.reason.rawValue
        self.hpFractionsA = replay.hpFractionsA
        self.hpFractionsB = replay.hpFractionsB
        self.faintedA = replay.faintedA
        self.faintedB = replay.faintedB
    }

    /// nil for a malformed replay — a bad one must not animate half a battle.
    var battleReplay: BattleReplay? {
        guard let seed = UInt64(seed), (0...1).contains(winnerSide),
              let reason = VictoryReason(rawValue: reason) else { return nil }
        return BattleReplay(
            seed: seed, events: events, winnerSide: winnerSide, turns: turns,
            reason: reason, hpFractionsA: hpFractionsA, hpFractionsB: hpFractionsB,
            faintedA: faintedA, faintedB: faintedB
        )
    }
}

// MARK: - Tournament bracket (display copy)

struct LANPairing: Codable, Equatable {
    var a: String?
    var b: String?
    var winner: String?
    /// A match is currently being played for this pairing.
    var live: Bool = false
}

struct LANBracket: Codable, Equatable {
    let rounds: [[LANPairing]]
    let champion: String?
}

// MARK: - Messages

/// Every message goes client ⇄ host. Clients never address each other, and
/// there is deliberately **no sender field**: the host identifies senders by
/// the connection they arrived on, so identity can't be spoofed.
enum LANMessage: Codable, Equatable {
    // Client → host
    case hello(player: LANPlayer)
    case challenge(target: String)
    case offerReply(matchID: UUID, accept: Bool)
    case commit(matchID: UUID, hash: Data)
    case reveal(matchID: UUID, nonce: Data, squad: Data)
    case startTournament
    case leave

    // Host → client
    case roster(players: [LANPlayer], busy: [String], hostID: String)
    case challengeRejected(target: String, reason: String)
    case matchOffer(matchID: UUID, challengerID: String)
    case matchStart(matchID: UUID, opponentID: String, side: Int, pickSeconds: Int, tournament: Bool)
    case revealNow(matchID: UUID)
    case replay(matchID: UUID, opponentSquad: Data, replay: LANReplay)
    case matchCancelled(matchID: UUID, reason: String)
    case bracket(LANBracket)
}

struct LANEnvelope: Codable, Equatable {
    let v: Int
    /// Unique per message, for dropping duplicates.
    let id: UUID
    let message: LANMessage
}

enum LANWire {
    static func encode(_ message: LANMessage) -> Data {
        let envelope = LANEnvelope(v: LANProtocolVersion.current, id: UUID(), message: message)
        return (try? JSONEncoder().encode(envelope)) ?? Data()
    }

    /// nil for garbage or a different protocol version.
    static func decode(_ data: Data) -> LANEnvelope? {
        guard let envelope = try? JSONDecoder().decode(LANEnvelope.self, from: data),
              envelope.v == LANProtocolVersion.current else { return nil }
        return envelope
    }
}
