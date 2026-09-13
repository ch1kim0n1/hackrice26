import Foundation
import CryptoKit

/// Commit/reveal primitives for LAN matches.
///
/// Each fighter commits to `SHA256(tag ‖ matchID ‖ len‖playerID ‖ side ‖ nonce ‖ squadBytes)`
/// before seeing anything of the opponent's, then reveals `(nonce, squadBytes)`.
/// That gives a blind squad pick (no counter-picking) and a seed neither side
/// can bias. Binding the match, player and side into the hash stops one
/// fighter replaying the other's commitment as their own.
enum LANCrypto {
    static let nonceLength = 32
    private static let tag = Data("nq-lan/v1".utf8)

    static func makeNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<nonceLength).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
    }

    /// The nonce is a fixed 32 bytes and the player id is length-prefixed, so
    /// no two different inputs can concatenate to the same buffer.
    static func commitment(matchID: UUID, playerID: String, side: Int, nonce: Data, squadBytes: Data) -> Data {
        var buffer = tag
        buffer.append(bytes(of: matchID))
        let idBytes = Data(playerID.utf8)
        buffer.append(withUnsafeBytes(of: UInt16(clamping: idBytes.count).bigEndian) { Data($0) })
        buffer.append(idBytes)
        buffer.append(UInt8(clamping: side))
        buffer.append(nonce)
        buffer.append(squadBytes)
        return Data(SHA256.hash(data: buffer))
    }

    /// Both nonces are committed before either is revealed, so neither
    /// fighter — including a host who is also fighting — can steer this.
    static func seed(matchID: UUID, nonceA: Data, nonceB: Data) -> UInt64 {
        var buffer = tag
        buffer.append(Data("seed".utf8))
        buffer.append(bytes(of: matchID))
        buffer.append(nonceA)
        buffer.append(nonceB)
        let digest = Array(SHA256.hash(data: buffer))
        return digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// Battle unit ids derived from (match, side, slot): the host and both
    /// clients compute identical ids, so replay events map back to characters
    /// without a UUID table on the wire.
    static func unitID(matchID: UUID, side: Int, slot: Int) -> UUID {
        var buffer = tag
        buffer.append(Data("unit".utf8))
        buffer.append(bytes(of: matchID))
        buffer.append(UInt8(clamping: side))
        buffer.append(UInt8(clamping: slot))
        let d = Array(SHA256.hash(data: buffer))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                           d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

    private static func bytes(of id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }
}
