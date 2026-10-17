import Foundation
import Network

/// Finds one Sonos player on the LAN via Bonjour (`_sonos._tcp`). The rest of
/// the household comes from that player's `GetZoneGroupState`.
enum Discovery {
    /// Returns "ip:1400" of the first player that resolves, or nil after `timeout`.
    static func findHost(timeout: TimeInterval = 5) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let session = Session(cont: cont)
            session.start(timeout: timeout)
        }
    }

    private final class Session {
        private var cont: CheckedContinuation<String?, Never>?
        private let browser = NWBrowser(for: .bonjour(type: "_sonos._tcp", domain: nil), using: .tcp)
        private var connections: [NWConnection] = []
        private var keepAlive: Session?

        init(cont: CheckedContinuation<String?, Never>) { self.cont = cont }

        func start(timeout: TimeInterval) {
            keepAlive = self
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                MainActor.assumeIsolated { self?.resolve(results) }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { self?.finish(nil) }
            }
        }

        private func resolve(_ results: Set<NWBrowser.Result>) {
            for result in results where connections.count < 4 {
                // Connecting to the advertised endpoint (TLS port 1443) resolves its IPv4 address.
                let params = NWParameters.tcp
                (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
                let conn = NWConnection(to: result.endpoint, using: params)
                conn.stateUpdateHandler = { [weak self, weak conn] state in
                    MainActor.assumeIsolated {
                        guard case .ready = state,
                              case let .hostPort(host, _)? = conn?.currentPath?.remoteEndpoint else { return }
                        var ip = "\(host)"
                        if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
                        self?.finish("\(ip):1400")
                    }
                }
                connections.append(conn)
                conn.start(queue: .main)
            }
        }

        private func finish(_ host: String?) {
            guard let cont else { return }
            self.cont = nil
            browser.cancel()
            connections.forEach { $0.cancel() }
            connections = []
            cont.resume(returning: host)
            keepAlive = nil
        }
    }
}
