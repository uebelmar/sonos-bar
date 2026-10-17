import Foundation
import Observation
import os

let log = Logger(subsystem: "at.uebeleis.sonosbar", category: "store")

/// App state + all Sonos actions. Polls only while the popover is visible.
@Observable
public final class SonosStore {
    public private(set) var groups: [SonosGroup] = []
    public private(set) var favorites: [MediaItem] = []
    public private(set) var playlists: [MediaItem] = []
    public private(set) var transport: [String: TransportInfo] = [:]       // by group id
    public private(set) var groupVolume: [String: Int] = [:]               // by group id
    public private(set) var groupMuted: [String: Bool] = [:]
    public private(set) var playerVolume: [String: Int] = [:]              // by player id
    public private(set) var isConnecting = false
    public var errorMessage: String?
    /// Favorites the speaker refused to load (UPnP 800) — usually content the
    /// service no longer offers. Kept for the session so the list can mark them.
    public private(set) var unavailable: Set<String> = []
    public var notice: String?

    public var selectedGroupID: String? {
        didSet { UserDefaults.standard.set(selectedGroup?.coordinator.name, forKey: Keys.selectedRoom) }
    }

    /// Group volume sliders being dragged — polling must not overwrite them.
    @ObservationIgnored private var draggingGroups: Set<String> = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lastTopologyRefresh = Date.distantPast
    @ObservationIgnored private var volumeTasks: [String: Task<Void, Never>] = [:]

    private enum Keys {
        static let host = "lastHost"
        static let selectedRoom = "selectedRoom"
    }

    public init() {}

    /// YouTube Music playlists the user saved as Sonos favorites (service id 284).
    /// Full library browsing is not possible: Google's SMAPI endpoint rejects
    /// controllers other than Sonos' own apps.
    public var youtubeFavorites: [MediaItem] {
        favorites.filter { $0.uri?.contains("sid=284") ?? false }
    }

    public var selectedGroup: SonosGroup? {
        groups.first { $0.id == selectedGroupID } ?? groups.first
    }

    public var allPlayers: [SonosPlayer] { groups.flatMap(\.members) }

    private var anyHost: String? {
        groups.first?.coordinator.host ?? UserDefaults.standard.string(forKey: Keys.host)
    }

    // MARK: Lifecycle

    public func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        var host = UserDefaults.standard.string(forKey: Keys.host)
        if let h = host, (try? await SonosClient(host: h).zoneGroups())?.isEmpty ?? true { host = nil }
        if host == nil { host = await Discovery.findHost() }
        guard let host else {
            log.error("discovery found no player")
            errorMessage = "Kein Sonos-System gefunden. Lokales Netzwerk in den Systemeinstellungen erlaubt?"
            return
        }
        UserDefaults.standard.set(host, forKey: Keys.host)
        errorMessage = nil
        await refreshTopology()
        await loadLibrary()
        await refreshState()
        log.info("connected via \(host, privacy: .public): \(self.groups.count) groups, \(self.favorites.count) favorites, \(self.playlists.count) playlists")
    }

    public func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.groups.isEmpty { await self.connect() }
                if Date().timeIntervalSince(self.lastTopologyRefresh) > 10 { await self.refreshTopology() }
                await self.refreshState()
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshTopology() async {
        guard let host = anyHost else { return }
        do {
            let fresh = try await SonosClient(host: host).zoneGroups()
            lastTopologyRefresh = Date()
            guard !fresh.isEmpty else { return }
            groups = fresh
            if selectedGroupID == nil || !fresh.contains(where: { $0.id == selectedGroupID }) {
                // Keep the room the user picked even if its group id changed after regrouping.
                let room = UserDefaults.standard.string(forKey: Keys.selectedRoom)
                selectedGroupID = (fresh.first { $0.members.contains { $0.name == room } } ?? fresh.first)?.id
            }
        } catch {
            // Remembered host gone (DHCP) — forget it so the next connect rediscovers.
            if groups.isEmpty { UserDefaults.standard.removeObject(forKey: Keys.host) }
        }
    }

    public func loadLibrary() async {
        guard let host = anyHost else { return }
        let client = SonosClient(host: host)
        if let fav = try? await client.browse("FV:2") { favorites = fav }
        if let sq = try? await client.browse("SQ:") { playlists = sq }
    }

    func refreshState() async {
        await withTaskGroup(of: Void.self) { tg in
            for group in groups {
                tg.addTask { await self.refresh(group) }
            }
        }
    }

    private func refresh(_ group: SonosGroup) async {
        let client = SonosClient(group.coordinator)
        if let info = try? await client.transportInfo() { transport[group.id] = info }
        if !draggingGroups.contains(group.id), let gv = try? await client.groupVolume() {
            groupVolume[group.id] = gv.volume
            groupMuted[group.id] = gv.muted
        }
        if group.members.count > 1 {
            for m in group.members where volumeTasks[m.id] == nil {
                if let v = try? await SonosClient(m).volume() { playerVolume[m.id] = v }
            }
        }
    }

    // MARK: Actions

    private func run(_ label: String, _ op: () async throws -> Void) async {
        do {
            try await op()
            errorMessage = nil
        } catch {
            log.error("\(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "\(label): \(error.localizedDescription)"
        }
    }

    public func play(_ item: MediaItem, on group: SonosGroup? = nil) async {
        guard let group = group ?? selectedGroup, let uri = item.uri else { return }
        let client = SonosClient(group.coordinator)
        do {
            if item.needsQueue {
                try await client.clearQueue()
                try await client.addToQueue(uri, metadata: item.metadata)
                try await client.setTransportURI("x-rincon-queue:\(group.coordinator.id)#0")
            } else {
                try await client.setTransportURI(uri, metadata: item.metadata)
            }
            try await client.play()
            errorMessage = nil
        } catch let fault as SOAPFault where fault.code == "800" {
            unavailable.insert(item.id)
            log.error("speaker refused \(item.title, privacy: .public)")
            errorMessage = "„\(item.title)“ kann nicht abgespielt werden – vom Dienst nicht (mehr) verfügbar. Mit 🗑 löschen."
        } catch {
            log.error("Abspielen failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Abspielen: \(error.localizedDescription)"
        }
        await refresh(group)
    }

    /// Removes a favorite from "My Sonos" (affects every Sonos app in the household).
    public func deleteFavorite(_ item: MediaItem) async {
        guard item.id.hasPrefix("FV:"), let host = anyHost else { return }
        do {
            try await SonosClient(host: host).destroyObject(item.id)
            unavailable.remove(item.id)
            favorites.removeAll { $0.id == item.id }
            errorMessage = nil
            notice = "„\(item.title)“ aus Mein Sonos gelöscht."
        } catch {
            errorMessage = "Löschen: \(error.localizedDescription)"
        }
        await loadLibrary()
    }

    public func togglePlay(_ group: SonosGroup) async {
        let client = SonosClient(group.coordinator)
        let playing = transport[group.id]?.isPlaying ?? false
        await run(playing ? "Pause" : "Play") { playing ? try await client.pause() : try await client.play() }
        await refresh(group)
    }

    public func next(_ group: SonosGroup) async {
        await run("Weiter") { try await SonosClient(group.coordinator).next() }
        await refresh(group)
    }

    public func previous(_ group: SonosGroup) async {
        await run("Zurück") { try await SonosClient(group.coordinator).previous() }
        await refresh(group)
    }

    /// Joins every reachable player into the selected group. One unreachable
    /// speaker (e.g. a portable on battery/Bluetooth) does not stop the rest.
    public func playEverywhere() async {
        guard let target = selectedGroup else { return }
        let coordID = target.coordinator.id
        let others = allPlayers.filter { p in !target.members.contains { $0.id == p.id } }
        var failed: [String] = []
        await withTaskGroup(of: String?.self) { tg in
            for p in others {
                tg.addTask { (try? await SonosClient(p).join(coordinatorID: coordID)) == nil ? p.name : nil }
            }
            for await name in tg { if let name { failed.append(name) } }
        }
        if !(transport[target.id]?.isPlaying ?? false) {
            try? await SonosClient(target.coordinator).play()
        }
        notice = failed.isEmpty ? nil : "Nicht erreichbar: \(failed.sorted().joined(separator: ", "))"
        try? await Task.sleep(for: .milliseconds(600))
        await refreshTopology()
        selectedGroupID = groups.first { $0.coordinator.id == coordID }?.id
        await refreshState()
    }

    /// Splits every group into single rooms.
    public func ungroupAll() async {
        let members = groups.flatMap { g in g.members.filter { $0.id != g.coordinator.id } }
        await withTaskGroup(of: Void.self) { tg in
            for p in members { tg.addTask { try? await SonosClient(p).leaveGroup() } }
        }
        notice = nil
        try? await Task.sleep(for: .milliseconds(600))
        await refreshTopology()
        await refreshState()
    }

    public func toggleMembership(_ player: SonosPlayer, in group: SonosGroup) async {
        let isMember = group.members.contains { $0.id == player.id }
        await run("Gruppieren") {
            if isMember { try await SonosClient(player).leaveGroup() }
            else { try await SonosClient(player).join(coordinatorID: group.coordinator.id) }
        }
        try? await Task.sleep(for: .milliseconds(500))
        await refreshTopology()
        await refreshState()
    }

    // MARK: Volume

    public func beginGroupVolumeChange(_ group: SonosGroup) {
        draggingGroups.insert(group.id)
        Task { try? await SonosClient(group.coordinator).snapshotGroupVolume() }
    }

    public func endGroupVolumeChange(_ group: SonosGroup) {
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            draggingGroups.remove(group.id)
        }
    }

    /// Debounced; ratios between members are kept via the snapshot taken in `beginGroupVolumeChange`.
    public func setGroupVolume(_ value: Int, for group: SonosGroup) {
        groupVolume[group.id] = value
        debounce(key: group.id) {
            let client = SonosClient(group.coordinator)
            if !self.draggingGroups.contains(group.id) { try? await client.snapshotGroupVolume() }
            try? await client.setGroupVolume(value)
        }
    }

    public func setVolume(_ value: Int, for player: SonosPlayer) {
        playerVolume[player.id] = value
        debounce(key: player.id) { try? await SonosClient(player).setVolume(value) }
    }

    public func toggleMute(_ group: SonosGroup) async {
        let muted = !(groupMuted[group.id] ?? false)
        groupMuted[group.id] = muted
        await run("Stumm") { try await SonosClient(group.coordinator).setGroupMute(muted) }
    }

    private func debounce(key: String, _ op: @escaping () async -> Void) {
        volumeTasks[key]?.cancel()
        volumeTasks[key] = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await op()
            volumeTasks[key] = nil
        }
    }
}
