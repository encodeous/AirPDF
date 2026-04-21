#if os(iOS)
import Foundation
import Combine
import Network
import os

/// Browses for AirPDF Mac hosts on the local network via Bonjour.
@MainActor
final class BonjourBrowser: ObservableObject {
    @Published private(set) var hosts: [DiscoveredHost] = []

    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]
    private let queue = DispatchQueue(label: "dev.airpdf.ipad.bonjour", qos: .userInitiated)
    private let logger = Logger(subsystem: "dev.airpdf.ipad", category: "BonjourBrowser")

    struct DiscoveredHost: Identifiable, Equatable {
        let id: String // service name
        let name: String
        let port: UInt16?
        let endpoint: NWEndpoint
    }

    init() {}

    func start() {
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: AirPDFConstants.bonjourServiceType,
            domain: AirPDFConstants.bonjourDomain
        )
        let browser = NWBrowser(for: descriptor, using: .udp)
        self.browser = browser
        logger.info("Starting Bonjour browser for \(AirPDFConstants.bonjourServiceType) on \(AirPDFConstants.bonjourDomain)")

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                self.logger.info("Browser state: \(String(describing: state))")
                if case .failed(let err) = state {
                    self.logger.error("Browser failed: \(err)")
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { @MainActor in
                self.logger.info("Browse results changed: \(results.count) result(s)")
                let current = results.compactMap { result -> DiscoveredHost? in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return DiscoveredHost(id: name, name: name, port: nil, endpoint: result.endpoint)
                }
                // Merge ports from any already-resolved hosts
                self.hosts = current.map { host in
                    if let existing = self.hosts.first(where: { $0.id == host.id }), let port = existing.port {
                        return DiscoveredHost(id: host.id, name: host.name, port: port, endpoint: host.endpoint)
                    }
                    return host
                }
                // Cancel resolvers for removed hosts
                let currentIds = Set(current.map(\.id))
                for id in self.resolvers.keys where !currentIds.contains(id) {
                    self.resolvers.removeValue(forKey: id)?.cancel()
                }
                // Start resolvers for new hosts without a port
                for host in self.hosts where host.port == nil && self.resolvers[host.id] == nil {
                    self.resolvePort(for: host)
                }
            }
        }
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        hosts = []
    }

    // MARK: - Port resolution

    private func resolvePort(for host: DiscoveredHost) {
        let conn = NWConnection(to: host.endpoint, using: .udp)
        resolvers[host.id] = conn
        conn.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            guard let remote = path.remoteEndpoint,
                  case .hostPort(_, let port) = remote else { return }
            Task { @MainActor in
                self.resolvers.removeValue(forKey: host.id)?.cancel()
                self.hosts = self.hosts.map { h in
                    h.id == host.id
                        ? DiscoveredHost(id: h.id, name: h.name, port: port.rawValue, endpoint: h.endpoint)
                        : h
                }
                self.logger.info("Resolved port \(port.rawValue) for '\(host.name)'")
            }
        }
        conn.start(queue: queue)
    }
}
#endif
