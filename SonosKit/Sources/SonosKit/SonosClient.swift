import Foundation

/// UPnP services of one Sonos player (local API, port 1400, no auth).
public enum Service {
    case avTransport, renderingControl, groupRenderingControl, zoneGroupTopology,
         contentDirectory, deviceProperties, systemProperties, musicServices

    var path: String {
        switch self {
        case .avTransport: "/MediaRenderer/AVTransport/Control"
        case .renderingControl: "/MediaRenderer/RenderingControl/Control"
        case .groupRenderingControl: "/MediaRenderer/GroupRenderingControl/Control"
        case .zoneGroupTopology: "/ZoneGroupTopology/Control"
        case .contentDirectory: "/MediaServer/ContentDirectory/Control"
        case .deviceProperties: "/DeviceProperties/Control"
        case .systemProperties: "/SystemProperties/Control"
        case .musicServices: "/MusicServices/Control"
        }
    }

    var urn: String {
        switch self {
        case .avTransport: "urn:schemas-upnp-org:service:AVTransport:1"
        case .renderingControl: "urn:schemas-upnp-org:service:RenderingControl:1"
        case .groupRenderingControl: "urn:schemas-upnp-org:service:GroupRenderingControl:1"
        case .zoneGroupTopology: "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
        case .contentDirectory: "urn:schemas-upnp-org:service:ContentDirectory:1"
        case .deviceProperties: "urn:schemas-upnp-org:service:DeviceProperties:1"
        case .systemProperties: "urn:schemas-upnp-org:service:SystemProperties:1"
        case .musicServices: "urn:schemas-upnp-org:service:MusicServices:1"
        }
    }
}

public struct TransportInfo: Equatable, Sendable {
    public var state: String          // PLAYING, PAUSED_PLAYBACK, STOPPED, TRANSITIONING
    public var title: String?
    public var artist: String?
    public var album: String?
    public var artURL: URL?

    public var isPlaying: Bool { state == "PLAYING" || state == "TRANSITIONING" }
}

/// Thin typed wrapper around the SOAP actions the app uses. All transport and
/// group commands must be sent to the group coordinator.
public struct SonosClient: Sendable {
    public let host: String   // "ip:1400"

    public init(host: String) { self.host = host }
    public init(_ player: SonosPlayer) { self.host = player.host }

    @discardableResult
    func call(_ service: Service, _ action: String, _ args: [(String, String)] = []) async throws -> XElement {
        let url = URL(string: "http://\(host)\(service.path)")!
        let body = SOAP.envelope(action: action, namespace: service.urn, args: args)
        return try await SOAP.call(url: url, soapAction: "\(service.urn)#\(action)", body: body)
    }

    private static let instance = ("InstanceID", "0")

    // MARK: Topology / library

    public func zoneGroups() async throws -> [SonosGroup] {
        let r = try await call(.zoneGroupTopology, "GetZoneGroupState")
        return Topology.parse(r.value("ZoneGroupState") ?? "")
    }

    /// Browses a ContentDirectory container ("FV:2" favorites, "SQ:" playlists).
    public func browse(_ objectID: String) async throws -> [MediaItem] {
        var items: [MediaItem] = []
        var start = 0
        while true {
            let r = try await call(.contentDirectory, "Browse", [
                ("ObjectID", objectID), ("BrowseFlag", "BrowseDirectChildren"), ("Filter", "*"),
                ("StartingIndex", "\(start)"), ("RequestedCount", "100"), ("SortCriteria", ""),
            ])
            let page = DIDL.parseBrowse(r.value("Result") ?? "")
            items += page
            let total = Int(r.value("TotalMatches") ?? "") ?? items.count
            start += Int(r.value("NumberReturned") ?? "") ?? page.count
            if page.isEmpty || start >= total { break }
        }
        return items
    }

    /// Deletes a Sonos favorite ("FV:2/…") or Sonos playlist ("SQ:…").
    public func destroyObject(_ objectID: String) async throws {
        try await call(.contentDirectory, "DestroyObject", [("ObjectID", objectID)])
    }

    public func householdID() async throws -> String {
        try await call(.deviceProperties, "GetHouseholdID").value("CurrentHouseholdID") ?? ""
    }

    /// Device id SMAPI services expect (same value the Sonos apps send).
    public func smapiDeviceID() async throws -> String {
        try await call(.systemProperties, "GetString", [("VariableName", "R_TrialZPSerial")]).value("StringValue") ?? ""
    }

    // MARK: Transport

    public func play() async throws { try await call(.avTransport, "Play", [Self.instance, ("Speed", "1")]) }
    public func pause() async throws { try await call(.avTransport, "Pause", [Self.instance]) }
    public func next() async throws { try await call(.avTransport, "Next", [Self.instance]) }
    public func previous() async throws { try await call(.avTransport, "Previous", [Self.instance]) }

    public func setTransportURI(_ uri: String, metadata: String = "") async throws {
        try await call(.avTransport, "SetAVTransportURI", [Self.instance, ("CurrentURI", uri), ("CurrentURIMetaData", metadata)])
    }

    public func clearQueue() async throws {
        try await call(.avTransport, "RemoveAllTracksFromQueue", [Self.instance])
    }

    public func addToQueue(_ uri: String, metadata: String) async throws {
        try await call(.avTransport, "AddURIToQueue", [
            Self.instance, ("EnqueuedURI", uri), ("EnqueuedURIMetaData", metadata),
            ("DesiredFirstTrackNumberEnqueued", "0"), ("EnqueueAsNext", "0"),
        ])
    }

    /// Leaves the current group (player becomes its own coordinator).
    public func leaveGroup() async throws {
        try await call(.avTransport, "BecomeCoordinatorOfStandaloneGroup", [Self.instance])
    }

    /// Joins the group led by `coordinatorID`.
    public func join(coordinatorID: String) async throws {
        try await setTransportURI("x-rincon:\(coordinatorID)")
    }

    public func transportInfo() async throws -> TransportInfo {
        async let t = call(.avTransport, "GetTransportInfo", [Self.instance])
        async let p = call(.avTransport, "GetPositionInfo", [Self.instance])
        async let m = call(.avTransport, "GetMediaInfo", [Self.instance])
        let (ti, pi, mi) = try await (t, p, m)

        let track = DIDL.parseTrack(pi.value("TrackMetaData") ?? "")
        let media = DIDL.parseTrack(mi.value("CurrentURIMetaData") ?? "")
        // Radio/HLS streams: track title is often the stream content, media title the station.
        let title = track.stream ?? track.title ?? media.title
        let artist = track.stream != nil ? media.title : track.artist
        return TransportInfo(
            state: ti.value("CurrentTransportState") ?? "STOPPED",
            title: title, artist: artist, album: track.album,
            artURL: artURL(track.art ?? media.art)
        )
    }

    func artURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http") { return URL(string: raw) }
        return URL(string: "http://\(host)\(raw.hasPrefix("/") ? "" : "/")\(raw)")
    }

    // MARK: Volume

    public func volume() async throws -> Int {
        Int(try await call(.renderingControl, "GetVolume", [Self.instance, ("Channel", "Master")]).value("CurrentVolume") ?? "") ?? 0
    }

    public func setVolume(_ v: Int) async throws {
        try await call(.renderingControl, "SetVolume", [Self.instance, ("Channel", "Master"), ("DesiredVolume", "\(v)")])
    }

    public func groupVolume() async throws -> (volume: Int, muted: Bool) {
        async let v = call(.groupRenderingControl, "GetGroupVolume", [Self.instance])
        async let m = call(.groupRenderingControl, "GetGroupMute", [Self.instance])
        let (vr, mr) = try await (v, m)
        return (Int(vr.value("CurrentVolume") ?? "") ?? 0, mr.value("CurrentMute") == "1")
    }

    /// Must precede `setGroupVolume` so member volumes keep their ratio.
    public func snapshotGroupVolume() async throws {
        try await call(.groupRenderingControl, "SnapshotGroupVolume", [Self.instance])
    }

    public func setGroupVolume(_ v: Int) async throws {
        try await call(.groupRenderingControl, "SetGroupVolume", [Self.instance, ("DesiredVolume", "\(v)")])
    }

    public func setGroupMute(_ muted: Bool) async throws {
        try await call(.groupRenderingControl, "SetGroupMute", [Self.instance, ("DesiredMute", muted ? "1" : "0")])
    }
}
