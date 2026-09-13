import Foundation

/// A single-elimination bracket for up to 8 players. Pure data — the host
/// decides when matches start; this only tracks who plays whom and who won.
///
/// Seeding uses the standard bracket order (1v8, 4v5, 2v7, 3v6…), padded to a
/// power of two. Byes land on the top seeds, so a bye is never paired with
/// another bye. A player who leaves hands their opponent a walkover — even if
/// that opponent is still finishing an earlier round ("pending walkover").
struct LANTournament {
    private(set) var rounds: [[LANPairing]]
    /// Seed order, index 0 = top seed.
    let seeds: [String]
    private(set) var gone: Set<String> = []
    private(set) var eliminated: Set<String> = []

    init(seeds players: [String]) {
        let seeds = Array(players.prefix(LANLimits.maxPlayers))
        self.seeds = seeds

        var size = 2
        while size < seeds.count { size *= 2 }
        let order = Self.seedOrder(size: size)

        var first: [LANPairing] = []
        for i in stride(from: 0, to: order.count, by: 2) {
            let a = order[i] <= seeds.count ? seeds[order[i] - 1] : nil
            let b = order[i + 1] <= seeds.count ? seeds[order[i + 1] - 1] : nil
            first.append(LANPairing(a: a, b: b, winner: nil))
        }

        var rounds = [first]
        var count = first.count
        while count > 1 {
            count /= 2
            rounds.append(Array(repeating: LANPairing(a: nil, b: nil, winner: nil), count: count))
        }
        self.rounds = rounds
        settleAutomatic()
    }

    /// 1-based seed placement: [1] → [1,2] → [1,4,2,3] → [1,8,4,5,2,7,3,6].
    static func seedOrder(size: Int) -> [Int] {
        var order = [1]
        while order.count < size {
            let n = order.count * 2
            order = order.flatMap { [$0, n + 1 - $0] }
        }
        return order
    }

    var champion: String? { rounds.last?.first?.winner }
    var isFinished: Bool { champion != nil }
    var bracket: LANBracket { LANBracket(rounds: rounds, champion: champion) }

    /// Still in contention — used to keep tournament players out of free
    /// challenges while the bracket runs.
    func isActiveParticipant(_ player: String) -> Bool {
        !isFinished && seeds.contains(player) && !eliminated.contains(player) && !gone.contains(player)
    }

    /// Pairings that can start now: both players known, undecided, not live.
    var ready: [(round: Int, index: Int, a: String, b: String)] {
        var result: [(round: Int, index: Int, a: String, b: String)] = []
        for r in rounds.indices {
            for i in rounds[r].indices {
                let p = rounds[r][i]
                if let a = p.a, let b = p.b, p.winner == nil, !p.live {
                    result.append((r, i, a, b))
                }
            }
        }
        return result
    }

    mutating func markLive(round r: Int, index i: Int) {
        guard rounds.indices.contains(r), rounds[r].indices.contains(i) else { return }
        rounds[r][i].live = true
    }

    mutating func record(winner: String, round r: Int, index i: Int) {
        guard rounds.indices.contains(r), rounds[r].indices.contains(i),
              rounds[r][i].winner == nil,
              winner == rounds[r][i].a || winner == rounds[r][i].b else { return }
        setWinner(winner, round: r, index: i)
        settleAutomatic()
    }

    mutating func playerLeft(_ player: String) {
        guard seeds.contains(player) else { return }
        gone.insert(player)
        settleAutomatic()
    }

    // MARK: - Private

    private mutating func setWinner(_ winner: String, round r: Int, index i: Int) {
        rounds[r][i].winner = winner
        rounds[r][i].live = false
        let pairing = rounds[r][i]
        for player in [pairing.a, pairing.b].compactMap({ $0 }) where player != winner {
            eliminated.insert(player)
        }
        guard r + 1 < rounds.count else { return }
        if i % 2 == 0 {
            rounds[r + 1][i / 2].a = winner
        } else {
            rounds[r + 1][i / 2].b = winner
        }
    }

    /// Byes and walkovers resolve themselves; repeat until nothing changes,
    /// since one result can unlock the next round's walkover.
    private mutating func settleAutomatic() {
        var changed = true
        while changed {
            changed = false
            for r in rounds.indices {
                for i in rounds[r].indices where rounds[r][i].winner == nil && !rounds[r][i].live {
                    let p = rounds[r][i]
                    // First-round bye: exactly one real player in the slot pair.
                    if r == 0 {
                        if let a = p.a, p.b == nil {
                            setWinner(a, round: r, index: i)
                            changed = true
                            continue
                        }
                        if let b = p.b, p.a == nil {
                            setWinner(b, round: r, index: i)
                            changed = true
                            continue
                        }
                    }
                    // Walkover once both sides are known. If the opponent
                    // isn't known yet, this waits — a pending walkover.
                    if let a = p.a, let b = p.b {
                        let aGone = gone.contains(a)
                        let bGone = gone.contains(b)
                        if aGone && !bGone {
                            setWinner(b, round: r, index: i)
                            changed = true
                        } else if bGone && !aGone {
                            setWinner(a, round: r, index: i)
                            changed = true
                        } else if aGone && bGone {
                            // Both left: keep the bracket moving.
                            setWinner(a, round: r, index: i)
                            changed = true
                        }
                    }
                }
            }
        }
    }
}
