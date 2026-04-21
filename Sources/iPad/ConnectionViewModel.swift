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

    /// Weak reference to the active DrawingViewController for remote stroke feedback.
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

    func sendUndoRedo(undo: Bool) {
        guard let docId = documentStore.documents.first?.id else { return }
        if undo {
            var msg = Airpdf_V1_Undo(); msg.documentID = docId
            client.send(.wrap(.undo(msg)))
        } else {
            var msg = Airpdf_V1_Redo(); msg.documentID = docId
            client.send(.wrap(.redo(msg)))
        }
    }

    func disconnect() {
        client.disconnectFromServer()
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
        case .strokeRemove, .strokeBatch:
            // Ignored — DrawingsUpdate is the authoritative state sync for undo/redo.
            // Individual StrokeRemove/StrokeBatch from Mac are always followed by DrawingsUpdate.
            break
        case .drawingsUpdate(let msg):
            // Authoritative drawing state from Mac (sent after every undo/redo).
            // Update both the document store and the live annotation coordinator.
            logger.info("Received DrawingsUpdate from Mac: doc=\(msg.documentID) pages=\(msg.pageDrawings.count)")
            documentStore.applyDrawingsUpdate(msg)
            for (k, v) in msg.pageDrawings {
                activeDrawingVC?.overlayCoordinator.applyRemoteDrawingUpdate(pageIndex: Int(k), drawingData: v)
            }
        default:
            break
        }
    }
}
#endif
