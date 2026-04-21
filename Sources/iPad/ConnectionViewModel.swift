#if os(iOS)
import Foundation
import Combine
import Network
import os

@MainActor
final class ConnectionViewModel: ObservableObject {
    @Published private(set) var client = QuicClient()
    @Published private(set) var browser = BonjourBrowser()
    let documentStore = DocumentStore()
    private let logger = Logger(subsystem: "dev.airpdf.ipad", category: "ConnectionViewModel")

    init() {
        browser.start()
        client.onMessage = { [weak self] envelope in
            self?.handleMessage(envelope)
        }
    }

    func connect(to host: BonjourBrowser.DiscoveredHost) {
        client.connect(to: host.endpoint)
    }

    func connectManual(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        client.connect(to: endpoint)
    }

    func disconnect() {
        client.disconnect()
        documentStore.closeAll()
    }

    private func handleMessage(_ envelope: Airpdf_V1_SyncEnvelope) {
        switch envelope.payload.body {
        case .pdfData(let msg):
            logger.info("Received PdfData: docId=\(msg.documentID) fileName=\(msg.fileName) bytes=\(msg.content.count)")
            documentStore.receive(msg)
        case .pdfClose(let msg):
            logger.info("Received PdfClose: docId=\(msg.documentID)")
            documentStore.close(documentId: msg.documentID)
        default:
            logger.info("Received unhandled message type")
        }
    }
}
#endif
