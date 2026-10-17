import Foundation
import Testing
@testable import SonosKit

/// Fixtures are real (redacted) responses from an S2 household, firmware 27.1.
private func response(_ name: String) throws -> XElement {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
    let root = try #require(XElement.parse(try Data(contentsOf: url)))
    return try #require(root.child("Body")?.children.first)
}

@Test func parsesZoneGroupState() throws {
    let r = try response("zgs")
    let groups = Topology.parse(try #require(r.value("ZoneGroupState")))

    #expect(groups.count == 6)
    #expect(groups.flatMap(\.members).count == 7)
    let buero = try #require(groups.first { $0.coordinator.name == "Büro" })
    #expect(buero.members.map(\.name) == ["Büro", "Tragbar"])
    #expect(buero.name == "Büro + Tragbar")
    #expect(buero.coordinator.host.hasSuffix(":1400"))
    #expect(buero.coordinator.id.hasPrefix("RINCON_"))
}

@Test func parsesFavoritesWithResMD() throws {
    let r = try response("favorites")
    let items = DIDL.parseBrowse(try #require(r.value("Result")))

    #expect(items.count == 4)
    let playlist = try #require(items.first { $0.uri?.hasPrefix("x-rincon-cpcontainer:") ?? false })
    #expect(playlist.needsQueue)
    #expect(playlist.subtitle == "YouTube Music")
    // Favorites must replay with their stored resMD, which carries the service token descriptor.
    #expect(playlist.metadata.hasPrefix("<DIDL-Lite"))
    #expect(playlist.metadata.contains("SA_RINCON72711_X_#Svc72711-"))
    #expect(playlist.albumArtURI?.hasPrefix("https://") ?? false)
}

@Test func parsesSonosPlaylists() throws {
    let r = try response("playlists")
    let items = DIDL.parseBrowse(try #require(r.value("Result")))

    #expect(items.count == 2)
    let first = try #require(items.first)
    #expect(first.id.hasPrefix("SQ:"))
    #expect(first.needsQueue)
    // No resMD: the container's own DIDL is sent and must be re-parseable.
    let reparsed = try #require(XElement.parse(first.metadata))
    #expect(reparsed.first("container")?["id"] == first.id)
    #expect(reparsed.first("title")?.text == first.title)
}

@Test func envelopeEscapesArguments() throws {
    let body = SOAP.envelope(action: "AddURIToQueue", namespace: Service.avTransport.urn,
                             args: [("EnqueuedURI", "x?a=1&b=2"), ("EnqueuedURIMetaData", "<DIDL-Lite/>")])
    #expect(body.contains("<EnqueuedURI>x?a=1&amp;b=2</EnqueuedURI>"))
    #expect(body.contains("&lt;DIDL-Lite/&gt;"))
    let action = try #require(XElement.parse(body)?.child("Body")?.children.first)
    #expect(action.value("EnqueuedURIMetaData") == "<DIDL-Lite/>")
}

@Test func streamItemsBypassQueue() {
    let stream = MediaItem(id: "1", title: "Radio", uri: "x-sonosapi-hls-static:abc?sid=284", metadata: "", albumArtURI: nil)
    #expect(!stream.needsQueue)
}

@Test func parsesTrackMetadata() {
    let didl = DIDL.header + #"<item id="-1" parentID="-1"><dc:title>Song</dc:title><dc:creator>Artist</dc:creator><upnp:album>Album</upnp:album><upnp:albumArtURI>/getaa?s=1</upnp:albumArtURI></item></DIDL-Lite>"#
    let t = DIDL.parseTrack(didl)
    #expect(t.title == "Song")
    #expect(t.artist == "Artist")
    #expect(SonosClient(host: "10.0.0.2:1400").artURL(t.art)?.absoluteString == "http://10.0.0.2:1400/getaa?s=1")
}
