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

/// One committed battle unit: what to draw (the app `Character`) plus the exact
/// base stats the engine fights with.
struct LANUnit: Codable, Equatable {
    let character: Character
    let element: String
    let rarity: String
    let fusionTier: Int
    let power: Double
    let guardStat: Double
    let vitality: Double
    let tempo: Double
}

struct LANSquad: Codable, Equatable {
    /// Exactly three, in battle order. Order matters: the engine always
    /// attacks the first living enemy.
    let units: [LANUnit]
    let partyMultiplier: Double
}

enum LANSquadError: Error, Equatable {
    case wrongSize
    case duplicateCharacters
    case statOutOfRange
    case fusionOutOfRange
    case unknownRarity
    case unknownElement
    case multiplierOutOfRange
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
        guard partyMultiplier.isFinite, (0.8...1.5).contains(partyMultiplier) else {
            throw LANSquadError.multiplierOutOfRange
        }
        for unit in units {
            for stat in [unit.power, unit.guardStat, unit.vitality, unit.tempo] {
                guard stat.isFinite, (10...100).contains(stat) else { throw LANSquadError.statOutOfRange }
            }
            guard (0...5).contains(unit.fusionTier) else { throw LANSquadError.fusionOutOfRange }
            guard Rarity(rawValue: unit.rarity) != nil else { throw LANSquadError.unknownRarity }
            guard BattleElement(rawValue: unit.element) != nil else { throw LANSquadError.unknownElement }
            let name = unit.character.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= LANLimits.maxNameLength else { throw LANSquadError.badName }
            guard unit.character.colorHex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
                throw LANSquadError.badColor
            }
        }
    }

    /// The engine-side squad. Unit UUIDs are derived from the match, side and
    /// slot, so the host and both clients agree on them without sending a map.
    func battleSquad(matchID: UUID, side: Int) -> BattleSquad {
        let battleUnits = units.enumerated().map { slot, unit -> BattleUnit in
            let character = FoodCharacter(
                id: LANCrypto.unitID(matchID: matchID, side: side, slot: slot),
                name: unit.character.name,
                barcode: unit.character.id,
                element: BattleElement(rawValue: unit.element) ?? .fiber,
                rarity: (Rarity(rawValue: unit.rarity) ?? .common).battleRarity,
                fusionTier: unit.fusionTier,
                baseStats: BattleStats(
                    power: unit.power,
                    guard: unit.guardStat,
                    vitality: unit.vitality,
                    tempo: unit.tempo
                )
            )
            return BattleUnit(character: character, partyMultiplier: partyMultiplier)
        }
        return BattleSquad(units: battleUnits)
    }
}

extension LANUnit {
    /// Build a unit from one of your own characters, clamped so it always
    /// passes `validate()` (long product names, odd colours, etc.).
    init(character: Character, stats: FoodCharacter) {
        var display = character
        let trimmed = character.name.trimmingCharacters(in: .whitespacesAndNewlines)
        display.name = trimmed.isEmpty ? "Mystery" : String(trimmed.prefix(LANLimits.maxNameLength))
        if character.colorHex.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) == nil {
            display.colorHex = "#9C978F"
        }
        let clamp: (Double) -> Double = { min(100, max(10, $0.isFinite ? $0 : 50)) }

        self.character = display
        self.element = stats.element.rawValue
        self.rarity = stats.rarity.appRarity.rawValue
        self.fusionTier = min(5, max(0, stats.fusionTier))
        self.power = clamp(stats.baseStats.power)
        self.guardStat = clamp(stats.baseStats.`guard`)
        self.vitality = clamp(stats.baseStats.vitality)
        self.tempo = clamp(stats.baseStats.tempo)
    }
}

// MARK: - Replay

/// `UInt64` seeds are sent as strings: JSON numbers above 2^53 don't survive
/// every decoder intact.
enum LANEvent: Codable, Equatable {
    case battleStart(seed: String)
    case roundStart(round: Int)
    case attack(attacker: UUID, defender: UUID, move: String, damage: Double, crit: Bool, typeMod: Double)
    case miss(attacker: UUID, defender: UUID)
    case faint(unit: UUID)
    case roundEnd(round: Int)
    case victory(winnerSide: Int, rounds: Int)
}

struct LANReplay: Codable, Equatable {
    let seed: String
    let events: [LANEvent]
    let winnerSide: Int
    let rounds: Int
}

extension LANEvent {
    init(_ event: BattleEvent) {
        switch event {
        case .battleStart(let seed): self = .battleStart(seed: String(seed))
        case .roundStart(let round): self = .roundStart(round: round)
        case .attack(let a, let d, let move, let damage, let crit, let typeMod):
            self = .attack(attacker: a, defender: d, move: move, damage: damage, crit: crit, typeMod: typeMod)
        case .miss(let a, let d): self = .miss(attacker: a, defender: d)
        case .faint(let unit): self = .faint(unit: unit)
        case .roundEnd(let round): self = .roundEnd(round: round)
        case .victory(let side, let rounds): self = .victory(winnerSide: side, rounds: rounds)
        }
    }

    var battleEvent: BattleEvent {
        switch self {
        case .battleStart(let seed): return .battleStart(seed: UInt64(seed) ?? 0)
        case .roundStart(let round): return .roundStart(round)
        case .attack(let a, let d, let move, let damage, let crit, let typeMod):
            return .attack(attackerID: a, defenderID: d, move: move, damage: damage, crit: crit, typeMod: typeMod)
        case .miss(let a, let d): return .miss(attackerID: a, defenderID: d)
        case .faint(let unit): return .faint(unitID: unit)
        case .roundEnd(let round): return .roundEnd(round)
        case .victory(let side, let rounds): return .victory(winnerSide: side, rounds: rounds)
        }
    }
}

extension LANReplay {
    init(_ replay: BattleReplay) {
        self.seed = String(replay.seed)
        self.events = replay.events.map { LANEvent($0) }
        self.winnerSide = replay.winnerSide
        self.rounds = replay.rounds
    }

    /// nil for a malformed seed — a bad replay must not animate half a battle.
    var battleReplay: BattleReplay? {
        guard let seed = UInt64(seed), (0...1).contains(winnerSide) else { return nil }
        return BattleReplay(seed: seed, events: events.map(\.battleEvent), winnerSide: winnerSide, rounds: rounds)
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
