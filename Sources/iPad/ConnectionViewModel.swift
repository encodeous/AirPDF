#if os(iOS)
import Foundation
import Combine

@MainActor
final class ConnectionViewModel: ObservableObject {
    @Published private(set) var client = QuicClient()
    @Published private(set) var browser = BonjourBrowser()

    init() {
        browser.start()
    }

    func connect(to host: BonjourBrowser.DiscoveredHost) {
        client.connect(to: host.endpoint)
    }

    func disconnect() {
        client.disconnect()
    }
}
#endif
