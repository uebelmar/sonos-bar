import Foundation
import Testing
@testable import SonosKit

@Test(.enabled(if: ProcessInfo.processInfo.environment["SONOS_LIVE"] != nil))
/// Live check against a real household: `SONOS_LIVE=1 SONOS_HOST=ip:1400 swift test --filter liveFavorites`.
/// Loads every YouTube Music favorite without pressing Play.
func liveFavorites() async throws {
    let c = SonosClient(host: ProcessInfo.processInfo.environment["SONOS_HOST"] ?? "")
    let favs = try await c.browse("FV:2")
    for item in favs where item.uri?.contains("sid=284") ?? false {
        do {
            if item.needsQueue {
                try await c.clearQueue()
                try await c.addToQueue(item.uri!, metadata: item.metadata)
            } else {
                try await c.setTransportURI(item.uri!, metadata: item.metadata)
            }
            print("OK  ", item.title.prefix(30))
        } catch {
            print("FAIL", item.title.prefix(30), error)
        }
    }
}
