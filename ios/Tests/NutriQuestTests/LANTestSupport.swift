import Foundation
@testable import NutriQuest
@testable import BattleKit

// Swift's stdlib also has a `Character`; name the app model explicitly.
typealias AppCharacter = NutriQuest.Character

enum LANFixtures {
    static let fixtureMoves: [BattleMoveSpec] = [
        BattleMoveSpec(id: "strike", name: "Strike", kind: .standard, power: 3.5, accuracy: 95, manaCost: 0)
    ]

    static func unit(_ id: String, name: String = "Unit", health: Double = 100, attack: Double = 50) -> LANUnit {
        LANUnit(
            character: AppCharacter(id: id, name: name, colorHex: "#5FCB82", rarity: .common),
            rarity: "common",
            star: 1,
            baseHealth: health,
            baseAttack: attack,
            baseMana: nil,
            moves: fixtureMoves
        )
    }

    /// Three distinct units: "<prefix>1", "<prefix>2", "<prefix>3".
    static func squad(_ prefix: String = "c", health: Double = 100, attack: Double = 50) -> LANSquad {
        LANSquad(units: [
            unit("\(prefix)1", health: health, attack: attack),
            unit("\(prefix)2", health: health, attack: attack),
            unit("\(prefix)3", health: health, attack: attack)
        ])
    }

    static func bytes(_ squad: LANSquad) -> Data {
        (try? JSONEncoder().encode(squad)) ?? Data()
    }
}

/// A fighter's commit/reveal material for driving `LANHostMatch` directly.
struct LANTestFighter {
    let id: String
    let side: Int
    let squad: LANSquad
    let nonce: Data
    let bytes: Data

    init(id: String, side: Int, squad: LANSquad, nonce: Data = LANCrypto.makeNonce()) {
        self.id = id
        self.side = side
        self.squad = squad
        self.nonce = nonce
        self.bytes = LANFixtures.bytes(squad)
    }

    func commitment(for matchID: UUID) -> Data {
        LANCrypto.commitment(matchID: matchID, playerID: id, side: side, nonce: nonce, squadBytes: bytes)
    }
}

final class LANTestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

/// A host and any number of clients wired in memory, synchronously. The host's
/// own player is a client on the loopback peer, exactly as on device.
@MainActor
final class LANTestGroup {
    let clock: LANTestClock
    let host: LANHost
    private(set) var clients: [String: LANClient] = [:]
    private var clientForPeer: [LANPeer: LANClient] = [:]
    private var peerForPlayer: [String: LANPeer] = [:]

    init(hostID: String = "host") {
        let clock = LANTestClock()
        self.clock = clock
        host = LANHost(hostID: hostID, clock: { clock.now })
        host.send = { [unowned self] data, peer in
            self.clientForPeer[peer]?.receive(data)
        }
        add(hostID, name: "Host", peer: .local)
    }

    @discardableResult
    func add(_ id: String, name: String? = nil, peer: LANPeer? = nil) -> LANClient {
        let peer = peer ?? LANPeer(id: "peer-\(id)-\(UUID().uuidString)")
        let clock = self.clock
        let client = LANClient(me: LANPlayer(id: id, name: name ?? id.capitalized), clock: { clock.now })
        client.send = { [unowned self] data in
            self.host.receive(data, from: peer)
        }
        clients[id] = client
        clientForPeer[peer] = client
        peerForPlayer[id] = peer
        client.connect()
        return client
    }

    subscript(id: String) -> LANClient { clients[id]! }

    func disconnect(_ id: String) {
        guard let peer = peerForPlayer.removeValue(forKey: id) else { return }
        clientForPeer[peer] = nil
        host.peerDisconnected(peer)
    }

    func advance(_ seconds: TimeInterval) {
        clock.now = clock.now.addingTimeInterval(seconds)
        host.tick()
    }

    /// Plays every match that's waiting on a squad pick until the group goes
    /// quiet: lock in, let the host simulate, dismiss the result (which moves
    /// a queued bracket match forward), repeat.
    func playOutMatches() async {
        for _ in 0..<12 {
            var acted = false
            for (id, client) in clients.sorted(by: { $0.key < $1.key }) {
                if let match = client.activeMatch, case .picking = match.phase {
                    client.lockIn(LANFixtures.squad(id))
                    acted = true
                }
            }
            await host.waitForResolutions()
            for client in clients.values {
                client.clearMatch()
            }
            let pending = clients.values.contains { client in
                if case .picking? = client.activeMatch?.phase { return true }
                return false
            }
            if !acted && !pending { break }
        }
    }
}

extension LANClient {
    var result: LANMatchResult? {
        if case .resolved(let value)? = activeMatch?.phase { return value }
        return nil
    }

    var cancellationReason: String? {
        if case .cancelled(let reason)? = activeMatch?.phase { return reason }
        return nil
    }
}
