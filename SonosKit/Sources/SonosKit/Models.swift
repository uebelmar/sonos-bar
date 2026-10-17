import Foundation

public struct SonosPlayer: Identifiable, Hashable, Sendable {
    public let id: String        // RINCON_… UUID
    public let name: String      // room name
    public let host: String      // "192.168.x.y:1400"

    public var baseURL: URL { URL(string: "http://\(host)")! }
}

public struct SonosGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let coordinator: SonosPlayer
    public let members: [SonosPlayer]   // coordinator first

    public var name: String {
        let others = members.filter { $0.id != coordinator.id }.map(\.name).sorted()
        return ([coordinator.name] + others).joined(separator: " + ")
    }
}

public enum Topology {
    /// Parses the (already unescaped) `ZoneGroupState` XML. Invisible members
    /// (bonded subs, surrounds, stereo-pair partners) are skipped.
    public static func parse(_ xml: String) -> [SonosGroup] {
        guard let root = XElement.parse(xml) else { return [] }
        let groupNodes = (root.name == "ZoneGroups" ? root : root.first("ZoneGroups"))?.children("ZoneGroup") ?? []

        return groupNodes.compactMap { node -> SonosGroup? in
            guard let coordID = node["Coordinator"] else { return nil }
            let players = node.children("ZoneGroupMember").compactMap { m -> SonosPlayer? in
                guard m["Invisible"] != "1", let uuid = m["UUID"], let name = m["ZoneName"],
                      let location = m["Location"], let url = URL(string: location),
                      let host = url.host else { return nil }
                return SonosPlayer(id: uuid, name: name, host: "\(host):\(url.port ?? 1400)")
            }
            guard let coordinator = players.first(where: { $0.id == coordID }) else { return nil }
            let members = [coordinator] + players.filter { $0.id != coordID }.sorted { $0.name < $1.name }
            return SonosGroup(id: node["ID"] ?? coordID, coordinator: coordinator, members: members)
        }
        .sorted { $0.coordinator.name.localizedCompare($1.coordinator.name) == .orderedAscending }
    }
}

/// A playable entry: Sonos favorite, Sonos playlist, or SMAPI (YouTube Music) item.
public struct MediaItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let uri: String?
    /// DIDL-Lite to send as `…MetaData` when playing. For favorites this is
    /// their stored `r:resMD`; otherwise the item's own DIDL.
    public let metadata: String
    public let albumArtURI: String?
    /// For browsable (SMAPI) containers that are not directly playable.
    public let isContainer: Bool
    public let canPlay: Bool

    public init(id: String, title: String, subtitle: String? = nil, uri: String?, metadata: String,
                albumArtURI: String?, isContainer: Bool = false, canPlay: Bool = true) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.uri = uri
        self.metadata = metadata
        self.albumArtURI = albumArtURI
        self.isContainer = isContainer
        self.canPlay = canPlay
    }

    /// Container URIs must go through the queue; everything else (streams,
    /// radio, single tracks) is set directly as transport URI.
    public var needsQueue: Bool {
        guard let uri else { return false }
        return uri.hasPrefix("x-rincon-cpcontainer:")
            || uri.hasPrefix("file:///jffs/settings/savedqueues")
            || uri.hasPrefix("x-rincon-playlist:")
    }
}

public enum DIDL {
    static let header = #"<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">"#

    /// Parses a ContentDirectory `Result` (FV:2 favorites or SQ: playlists).
    public static func parseBrowse(_ xml: String) -> [MediaItem] {
        guard let root = XElement.parse(xml) else { return [] }
        return root.children.compactMap { node -> MediaItem? in
            guard node.name == "item" || node.name == "container", let id = node["id"] else { return nil }
            let title = node.value("title") ?? "?"
            let uri = node.value("res")
            let resMD = node.value("resMD").flatMap { $0.isEmpty ? nil : $0 }
            let ownDIDL = header + xmlString(node) + "</DIDL-Lite>"
            return MediaItem(
                id: id, title: title, subtitle: node.value("description"),
                uri: uri, metadata: resMD ?? ownDIDL,
                albumArtURI: node.value("albumArtURI"),
                canPlay: uri != nil && !(uri ?? "").isEmpty
            )
        }
    }

    /// Track info from `GetPositionInfo.TrackMetaData` / `GetMediaInfo.CurrentURIMetaData`.
    public static func parseTrack(_ xml: String) -> (title: String?, artist: String?, album: String?, art: String?, stream: String?) {
        guard let item = XElement.parse(xml)?.first("item") else { return (nil, nil, nil, nil, nil) }
        func v(_ n: String) -> String? { item.value(n).flatMap { $0.isEmpty ? nil : $0 } }
        return (v("title"), v("creator") ?? v("albumArtist"), v("album"), v("albumArtURI"), v("streamContent"))
    }

    /// Re-serializes a parsed node (used to send a container's own DIDL back).
    static func xmlString(_ node: XElement) -> String {
        let prefix: String = switch node.name {
        case "title", "creator": "dc:"
        case "class", "albumArtURI", "album", "artist": "upnp:"
        case "description", "type", "ordinal", "resMD": "r:"
        default: ""
        }
        let attrs = node.attributes.sorted { $0.key < $1.key }.map { " \($0.key)=\"\($0.value.xmlEscaped)\"" }.joined()
        let inner = node.children.isEmpty ? node.text.xmlEscaped : node.children.map(xmlString).joined()
        return "<\(prefix)\(node.name)\(attrs)>\(inner)</\(prefix)\(node.name)>"
    }
}
