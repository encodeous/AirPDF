#if os(iOS)
import Foundation
import Combine
import Network
import PencilKit
import os

@MainActor
final class ConnectionViewModel: ObservableObject {
    @Published private(set) var client = QuicClient()
    @Published private(set) var browser = BonjourBrowser()
    let documentStore = DocumentStore()
    private let logger = Logger(subsystem: "dev.airpdf.ipad", category: "ConnectionViewModel")

    weak var activeDrawingVC: DrawingViewController?

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

    func send(_ envelope: Airpdf_V1_SyncEnvelope) {
        client.send(envelope)
    }

    func disconnect() {
        client.disconnectFromServer()
        documentStore.closeAll()
        activeDrawingVC = nil
    }

    private func handleMessage(_ envelope: Airpdf_V1_SyncEnvelope) {
        switch envelope.payload.body {
        case .pdfData(let msg):
            logger.info("Received PdfData: docId=\(msg.documentID) fileName=\(msg.fileName) bytes=\(msg.content.count)")
            documentStore.receive(msg)
        case .pdfClose(let msg):
            logger.info("Received PdfClose: docId=\(msg.documentID)")
            documentStore.close(documentId: msg.documentID)
            activeDrawingVC = nil
        case .strokeRemove, .strokeBatch:
            break
        case .drawingsUpdate(let msg):
            logger.info("Received DrawingsUpdate from Mac: doc=\(msg.documentID) pages=\(msg.pageStrokes.count)")
            // Full snapshot replace — decode and push directly to the VC's model
            let strokes = StrokeModel.decodePageStrokes(msg.pageStrokes)
            activeDrawingVC?.applySnapshot(strokes)
        default:
            break
        }
    }
}
#endif
