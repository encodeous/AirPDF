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
    private let queue = DispatchQueue(label: "dev.airpdf.ipad.bonjour", qos: .userInitiated)
    private let logger = Logger(subsystem: "dev.airpdf.ipad", category: "BonjourBrowser")

    struct DiscoveredHost: Identifiable, Equatable {
        let id: String // service name
        let name: String
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

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            Task { @MainActor in
                self.logger.info("Browse results changed: \(results.count) result(s), changes: \(changes.count)")
                for result in results {
                    self.logger.info("  Found endpoint: \(String(describing: result.endpoint))")
                }
                self.hosts = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return DiscoveredHost(id: name, name: name, endpoint: result.endpoint)
                }
            }
        }
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        hosts = []
    }
}
#endif
