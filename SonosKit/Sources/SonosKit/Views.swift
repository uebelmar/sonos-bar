import SwiftUI

struct PopoverView: View {
    @Bindable var store: SonosStore
    @State private var tab: Tab = Tab(rawValue: UserDefaults.standard.string(forKey: "initialTab") ?? "") ?? .youtube

    enum Tab: String, CaseIterable, Identifiable {
        case youtube = "YouTube Music", rooms = "Räume", favorites = "Favoriten", playlists = "Playlists"

        init?(rawValue: String) {
            switch rawValue {
            case "YouTube Music", "youtube": self = .youtube
            case "Räume", "rooms": self = .rooms
            case "Favoriten", "favorites": self = .favorites
            case "Playlists", "playlists": self = .playlists
            default: return nil
            }
        }
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let group = store.selectedGroup {
                NowPlayingView(store: store, group: group)
                    .padding(12)
                actionBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                emptyState
            }

            if let message = store.errorMessage ?? store.notice {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(store.errorMessage != nil ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                switch tab {
                case .rooms: RoomsView(store: store)
                case .youtube: LibraryList(store: store, items: store.youtubeFavorites,
                                           empty: "Keine YouTube-Music-Favoriten.\nIn der Sonos-App eine Playlist mit ♡ zu „Mein Sonos“ hinzufügen.")
                case .favorites: LibraryList(store: store, items: store.favorites, empty: "Keine Sonos-Favoriten.")
                case .playlists: LibraryList(store: store, items: store.playlists, empty: "Keine Sonos-Playlists.")
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 380, height: 580)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await store.playEverywhere() }
            } label: {
                Label("Überall abspielen", systemImage: "hifispeaker.2.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.groups.count < 2)

            Button {
                Task { await store.ungroupAll() }
            } label: {
                Image(systemName: "square.split.2x1")
            }
            .controlSize(.large)
            .help("Alle Gruppen auflösen")
            .disabled(!store.groups.contains { $0.members.count > 1 })
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if store.isConnecting {
                ProgressView()
                Text("Suche Sonos im Netzwerk …").font(.callout).foregroundStyle(.secondary)
            } else {
                Image(systemName: "hifispeaker.slash").font(.largeTitle).foregroundStyle(.secondary)
                Button("Erneut suchen") { Task { await store.connect() } }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

// MARK: - Now playing

struct NowPlayingView: View {
    let store: SonosStore
    let group: SonosGroup

    var body: some View {
        let info = store.transport[group.id]
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Artwork(url: info?.artURL, size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Menu {
                        ForEach(store.groups) { g in
                            Button(g.name) { store.selectedGroupID = g.id }
                        }
                    } label: {
                        Text(group.name).font(.caption).lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Text(info?.title ?? "Nichts in Wiedergabe")
                        .font(.headline).lineLimit(2)
                    if let artist = info?.artist {
                        Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 22) {
                Button { Task { await store.previous(group) } } label: { Image(systemName: "backward.fill") }
                Button { Task { await store.togglePlay(group) } } label: {
                    Image(systemName: info?.isPlaying == true ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 34))
                }
                Button { Task { await store.next(group) } } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.plain)
            .font(.title3)
            GroupVolumeSlider(store: store, group: group)
        }
    }
}

struct Artwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 40 ? 8 : 4))
    }
}

// MARK: - Volume

struct GroupVolumeSlider: View {
    let store: SonosStore
    let group: SonosGroup

    var body: some View {
        let muted = store.groupMuted[group.id] ?? false
        HStack(spacing: 8) {
            Button { Task { await store.toggleMute(group) } } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(muted ? .red : .secondary)
            VolumeStepButton(systemImage: "minus") { step(-VolumeStepButton.step) }
            Slider(
                value: Binding(
                    get: { Double(store.groupVolume[group.id] ?? 0) },
                    set: { store.setGroupVolume(Int($0.rounded()), for: group) }
                ),
                in: 0...100
            ) { editing in
                editing ? store.beginGroupVolumeChange(group) : store.endGroupVolumeChange(group)
            }
            .controlSize(.small)
            VolumeStepButton(systemImage: "plus") { step(VolumeStepButton.step) }
            Text("\(store.groupVolume[group.id] ?? 0)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }

    private func step(_ delta: Int) {
        let v = min(100, max(0, (store.groupVolume[group.id] ?? 0) + delta))
        store.setGroupVolume(v, for: group)
    }
}

/// Small −/+ button next to a volume slider; holding it repeats.
struct VolumeStepButton: View {
    static let step = 2

    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .foregroundStyle(.secondary)
        .help(systemImage == "plus" ? "Lauter" : "Leiser")
    }
}

struct PlayerVolumeSlider: View {
    let store: SonosStore
    let player: SonosPlayer

    var body: some View {
        HStack(spacing: 8) {
            Text(player.name).font(.caption).frame(width: 90, alignment: .leading).lineLimit(1)
            VolumeStepButton(systemImage: "minus") { step(-VolumeStepButton.step) }
            Slider(
                value: Binding(
                    get: { Double(store.playerVolume[player.id] ?? 0) },
                    set: { store.setVolume(Int($0.rounded()), for: player) }
                ),
                in: 0...100
            )
            .controlSize(.mini)
            VolumeStepButton(systemImage: "plus") { step(VolumeStepButton.step) }
            Text("\(store.playerVolume[player.id] ?? 0)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }

    private func step(_ delta: Int) {
        let v = min(100, max(0, (store.playerVolume[player.id] ?? 0) + delta))
        store.setVolume(v, for: player)
    }
}

// MARK: - Rooms

struct RoomsView: View {
    let store: SonosStore

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(store.groups) { group in
                GroupRow(store: store, group: group)
                Divider().padding(.leading, 12)
            }
        }
    }
}

struct GroupRow: View {
    let store: SonosStore
    let group: SonosGroup
    @State private var expanded = false

    var body: some View {
        let selected = store.selectedGroup?.id == group.id
        let info = store.transport[group.id]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: info?.isPlaying == true ? "waveform" : "hifispeaker")
                    .foregroundStyle(info?.isPlaying == true ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                    if let title = info?.title, info?.isPlaying == true {
                        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button { Task { await store.togglePlay(group) } } label: {
                    Image(systemName: info?.isPlaying == true ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { store.selectedGroupID = group.id }

            GroupVolumeSlider(store: store, group: group)

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if group.members.count > 1 {
                        ForEach(group.members) { PlayerVolumeSlider(store: store, player: $0) }
                    }
                    Text("Räume in dieser Gruppe").font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(store.allPlayers.sorted { $0.name < $1.name }) { player in
                        let isMember = group.members.contains { $0.id == player.id }
                        Toggle(player.name, isOn: Binding(
                            get: { isMember },
                            set: { _ in Task { await store.toggleMembership(player, in: group) } }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .disabled(player.id == group.coordinator.id)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.08) : .clear)
    }
}

// MARK: - Library

struct LibraryList: View {
    let store: SonosStore
    let items: [MediaItem]
    let empty: String

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3)

    var body: some View {
        if items.isEmpty {
            Text(empty)
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(24)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let group = store.selectedGroup {
                    Text("Spielt auf: \(group.name)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { item in
                        LibraryCard(store: store, item: item)
                    }
                }
            }
            .padding(12)
        }
    }
}

struct LibraryCard: View {
    let store: SonosStore
    let item: MediaItem
    @State private var hovering = false
    @State private var confirmDelete = false

    private var unavailable: Bool { store.unavailable.contains(item.id) }
    private var deletable: Bool { item.id.hasPrefix("FV:") }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            cover
            Text(item.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            if let subtitle = item.subtitle, subtitle != "YouTube Music" {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .opacity(unavailable ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard item.canPlay, !unavailable else { return }
            Task { await store.play(item) }
        }
        .onHover { hovering = $0 }
        .help(item.title)
        .contextMenu {
            if deletable {
                Button("Aus Mein Sonos löschen …", role: .destructive) { confirmDelete = true }
            }
        }
        .confirmationDialog("„\(item.title)“ aus Mein Sonos löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) { Task { await store.deleteFavorite(item) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Favorit verschwindet in allen Sonos-Apps. Das lässt sich nicht rückgängig machen.")
        }
    }

    private var cover: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: item.albumArtURI.flatMap(URL.init(string:))) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note.list").font(.title2).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if hovering && !unavailable && item.canPlay {
                    ZStack {
                        Color.black.opacity(0.35)
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.white)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if unavailable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.white, .orange)
                        .padding(5)
                        .help("Nicht verfügbar")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if unavailable && deletable {
                    Button { confirmDelete = true } label: {
                        Image(systemName: "trash.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .red)
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help("Aus Mein Sonos löschen")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.1), radius: hovering ? 6 : 2, y: 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
