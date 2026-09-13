import Foundation
import UIKit
import BattleKit

/// Owns one LAN group from the UI's point of view: discovery, hosting or
/// joining, and the wiring between MultipeerConnectivity, the host
/// coordinator and this device's `LANClient`.
@MainActor
final class LANSession: ObservableObject {
    enum Role: Equatable {
        case idle, browsing, hosting, joining, joined
    }

    @Published private(set) var role: Role = .idle
    @Published private(set) var groups: [LANDiscoveredGroup] = []
    @Published private(set) var groupName: String?
    @Published var error: String?
    /// iOS offers no API to read local-network permission; if nothing shows up
    /// for a while, point the player at Settings.
    @Published private(set) var showPermissionHint = false

    let me: LANPlayer
    let client: LANClient

    private var host: LANHost?
    private var multipeer: LANMultipeer?
    private var ticker: Timer?
    private var hintTask: Task<Void, Never>?

    var isInGroup: Bool { role == .hosting || role == .joined }

    init() {
        let rawName = SessionStore.shared.displayName ?? SessionStore.shared.username ?? ""
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let playerID = SessionStore.shared.playerID ?? AppConfig.playerID
        let name = trimmed.isEmpty ? "Player \(playerID.suffix(4))" : String(trimmed.prefix(LANLimits.maxNameLength))
        let player = LANPlayer(id: playerID, name: name)
        me = player
        client = LANClient(me: player)
    }

    // MARK: - Discovery

    func browse() {
        guard role == .idle || role == .browsing else { return }
        makeMultipeer().startBrowsing()
        role = .browsing
        groups = []
        showPermissionHint = false
        hintTask?.cancel()
        hintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled, self.role == .browsing, self.groups.isEmpty else { return }
            self.showPermissionHint = true
        }
    }

    // MARK: - Hosting

    func hostGroup(named rawName: String) {
        guard role == .idle || role == .browsing else { return }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "\(me.name)'s group" : String(trimmed.prefix(32))
        let multipeer = makeMultipeer()
        let host = LANHost(hostID: me.id)

        // The host's own player talks to the coordinator in-process.
        host.send = { [weak self] data, peer in
            guard let self else { return }
            if peer == .local {
                self.client.receive(data)
            } else {
                self.multipeer?.send(data, to: peer)
            }
        }
        client.send = { [weak host] data in host?.receive(data, from: .local) }
        multipeer.onData = { [weak host] data, peer in host?.receive(data, from: peer) }
        multipeer.onDisconnected = { [weak host] peer in host?.peerDisconnected(peer) }
        multipeer.startHosting(hostID: me.id, groupName: name)

        self.host = host
        groupName = name
        role = .hosting
        hintTask?.cancel()
        client.connect()
        startTicker()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    // MARK: - Joining

    func join(_ group: LANDiscoveredGroup) {
        guard role == .browsing else { return }
        guard group.version == LANProtocolVersion.current else {
            error = "That group is running a different version of the app."
            return
        }
        let multipeer = makeMultipeer()
        client.send = { [weak multipeer] data in multipeer?.sendToHost(data) }
        multipeer.onData = { [weak self] data, _ in self?.client.receive(data) }
        multipeer.onHostConnected = { [weak self] in
            guard let self else { return }
            self.role = .joined
            self.client.connect()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        multipeer.onDisconnected = { [weak self] _ in
            guard let self else { return }
            let wasInGroup = self.role == .joined
            self.leave()
            self.error = wasInGroup ? "The host left the group." : "Couldn't join that group."
        }
        groupName = group.name
        role = .joining
        hintTask?.cancel()
        multipeer.join(group)
    }

    // MARK: - Leaving

    func leave() {
        if role == .joined { client.leave() }
        ticker?.invalidate()
        ticker = nil
        hintTask?.cancel()
        hintTask = nil
        multipeer?.stopAll()
        multipeer = nil
        host = nil
        groups = []
        groupName = nil
        showPermissionHint = false
        role = .idle
        client.reset()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Private

    private func makeMultipeer() -> LANMultipeer {
        if let multipeer { return multipeer }
        let multipeer = LANMultipeer(displayName: me.name)
        multipeer.onGroupsChanged = { [weak self] groups in
            guard let self else { return }
            // Never list your own group.
            self.groups = groups.filter { $0.id != self.me.id }
            if !self.groups.isEmpty { self.showPermissionHint = false }
        }
        multipeer.onError = { [weak self] message in self?.error = message }
        self.multipeer = multipeer
        return multipeer
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.host?.tick() }
        }
    }
}

extension GameState {
    /// Your picked characters as a committable squad, carrying the same
    /// battle snapshot every other mode uses. Nutrition adherence never
    /// buffs combat (final-dev-doc §7) — there is no party multiplier.
    func lanSquad(from characters: [Character]) -> LANSquad? {
        let units = characters.map { LANUnit(character: $0, spec: battleStats(for: $0)) }
        guard units.count == 3 else { return nil }
        return LANSquad(units: units)
    }
}
