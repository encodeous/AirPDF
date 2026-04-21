#if os(iOS)
import Foundation
import Combine
import Network

/// Browses for AirPDF Mac hosts on the local network via Bonjour.
@MainActor
final class BonjourBrowser: ObservableObject {
    @Published private(set) var hosts: [DiscoveredHost] = []

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "dev.airpdf.ipad.bonjour", qos: .userInitiated)

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
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.hosts = results.compactMap { result in
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
