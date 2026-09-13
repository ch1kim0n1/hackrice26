import Foundation
import MultipeerConnectivity

/// A group visible on the local network.
struct LANDiscoveredGroup: Identifiable, Equatable {
    /// The host's player id — stable across relaunches, unlike its MCPeerID,
    /// so a host that restarted doesn't show up twice.
    let id: String
    let name: String
    let version: Int
    let peer: MCPeerID
}

/// Thin MultipeerConnectivity glue. Deliberately dumb: it moves bytes and
/// reports connections; every rule lives in `LANHost` / `LANClient`, which is
/// what the tests exercise.
///
/// Topology: the host advertises and accepts invitations; joiners browse and
/// invite the host, and **never advertise**. MPC may still mesh joiners
/// together, but they only ever talk to the host.
@MainActor
final class LANMultipeer: NSObject {
    /// Bonjour: `_nq-lan._tcp` / `_nq-lan._udp` (declared in Info.plist).
    static let serviceType = "nq-lan"
    /// The host's own messages on a joiner, under one fixed handle.
    static let hostHandle = LANPeer(id: "host")

    private let peerID: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var handles: [MCPeerID: LANPeer] = [:]
    private var peersByHandle: [LANPeer: MCPeerID] = [:]
    private var found: [MCPeerID: LANDiscoveredGroup] = [:]
    private var hostPeer: MCPeerID?
    private var isHosting = false

    var onData: ((Data, LANPeer) -> Void)?
    var onDisconnected: ((LANPeer) -> Void)?
    var onHostConnected: (() -> Void)?
    var onGroupsChanged: (([LANDiscoveredGroup]) -> Void)?
    var onError: ((String) -> Void)?

    init(displayName: String) {
        peerID = LANMultipeer.persistentPeerID(displayName: displayName)
        // Encryption off: it's casual game data, and `.required` is the
        // least reliable MPC setting in practice.
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .none)
        super.init()
        session.delegate = self
    }

    // MARK: - Roles

    func startHosting(hostID: String, groupName: String) {
        stopAll()
        isHosting = true
        let advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: [
                "hostID": hostID,
                "name": String(groupName.prefix(40)),
                "v": String(LANProtocolVersion.current)
            ],
            serviceType: Self.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
    }

    func startBrowsing() {
        stopAll()
        isHosting = false
        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func join(_ group: LANDiscoveredGroup) {
        guard let browser else { return }
        hostPeer = group.peer
        browser.invitePeer(group.peer, to: session, withContext: nil, timeout: 20)
    }

    /// Host → one joiner.
    func send(_ data: Data, to handle: LANPeer) {
        guard let peer = peersByHandle[handle] else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
    }

    /// Joiner → host. Never to other joiners, even if MPC meshed us.
    func sendToHost(_ data: Data) {
        guard let hostPeer else { return }
        try? session.send(data, toPeers: [hostPeer], with: .reliable)
    }

    func stopAll() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser = nil
        session.disconnect()
        handles = [:]
        peersByHandle = [:]
        found = [:]
        hostPeer = nil
        isHosting = false
    }

    // MARK: - Main-actor handlers

    private func handle(for peer: MCPeerID) -> LANPeer {
        if let existing = handles[peer] { return existing }
        let handle = LANPeer(id: UUID().uuidString)
        handles[peer] = handle
        peersByHandle[handle] = peer
        return handle
    }

    fileprivate func peerChanged(_ peer: MCPeerID, state: MCSessionState) {
        switch state {
        case .connected:
            if isHosting {
                _ = handle(for: peer)
            } else if peer == hostPeer {
                browser?.stopBrowsingForPeers()
                onHostConnected?()
            }
        case .notConnected:
            if isHosting {
                if let handle = handles.removeValue(forKey: peer) {
                    peersByHandle[handle] = nil
                    onDisconnected?(handle)
                }
            } else if peer == hostPeer {
                hostPeer = nil
                onDisconnected?(Self.hostHandle)
            }
        case .connecting:
            break
        @unknown default:
            break
        }
    }

    fileprivate func received(_ data: Data, from peer: MCPeerID) {
        if isHosting {
            onData?(data, handle(for: peer))
        } else if peer == hostPeer {
            onData?(data, Self.hostHandle)
        }
    }

    fileprivate func invitation(from peer: MCPeerID, reply: @escaping (Bool, MCSession?) -> Void) {
        // 8 peers per session, the host included.
        let accept = isHosting && session.connectedPeers.count < LANLimits.maxPlayers - 1
        reply(accept, accept ? session : nil)
    }

    fileprivate func foundPeer(_ peer: MCPeerID, info: [String: String]?) {
        guard let info, let hostID = info["hostID"], let name = info["name"] else { return }
        // One entry per host id: drop any stale MCPeerID for the same host.
        found = found.filter { $0.value.id != hostID }
        found[peer] = LANDiscoveredGroup(id: hostID, name: name, version: Int(info["v"] ?? "") ?? 0, peer: peer)
        onGroupsChanged?(found.values.sorted { $0.name < $1.name })
    }

    fileprivate func lostPeer(_ peer: MCPeerID) {
        found[peer] = nil
        onGroupsChanged?(found.values.sorted { $0.name < $1.name })
    }

    fileprivate func reportError(_ message: String) {
        onError?(message)
    }

    // MARK: - Identity

    /// One MCPeerID per install. A fresh one every launch leaves ghost
    /// entries in other players' lists.
    private static func persistentPeerID(displayName: String) -> MCPeerID {
        let name = safeDisplayName(displayName)
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "lan.peerName") == name,
           let data = defaults.data(forKey: "lan.peerID"),
           let saved = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data) {
            return saved
        }
        let peer = MCPeerID(displayName: name)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: peer, requiringSecureCoding: true) {
            defaults.set(data, forKey: "lan.peerID")
            defaults.set(name, forKey: "lan.peerName")
        }
        return peer
    }

    /// MCPeerID needs a non-empty name of at most 63 UTF-8 bytes.
    private static func safeDisplayName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Player" }
        while name.utf8.count > 63 { name.removeLast() }
        return name
    }
}

// MARK: - Delegates
//
// MPC calls these on its own background queue; each hops to the main actor
// before touching any state.

extension LANMultipeer: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in self?.peerChanged(peerID, state: state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in self?.received(data, from: peerID) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                             withName streamName: String, fromPeer peerID: MCPeerID) {}

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    /// Must always answer, or the peer sits in "connecting" and then drops.
    nonisolated func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?,
                             fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }
}

extension LANMultipeer: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else {
                invitationHandler(false, nil)
                return
            }
            self.invitation(from: peerID, reply: invitationHandler)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        let message = "Couldn't start hosting: \(error.localizedDescription)"
        Task { @MainActor [weak self] in self?.reportError(message) }
    }
}

extension LANMultipeer: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor [weak self] in self?.foundPeer(peerID, info: info) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in self?.lostPeer(peerID) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        let message = "Couldn't search for groups: \(error.localizedDescription)"
        Task { @MainActor [weak self] in self?.reportError(message) }
    }
}
