#if os(macOS)
import Foundation
import Combine
import PDFKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [DocumentSession] = []
    @Published var selectedSessionID: UUID?
    @Published var lastError: String?

    let server = QuicServer()
    private let store = DocumentSessionStore()

    init() {
        server.onClientConnected = { [weak self] client in
            self?.onClientConnected(client)
        }
        server.onClientDisconnected = { [weak self] in
            self?.lastError = nil
        }
    }

    // MARK: - Documents

    @discardableResult
    func openPDF(at url: URL) -> Bool {
        guard let document = PDFDocument(url: url) else {
            lastError = "Unable to open \(url.lastPathComponent)."
            return false
        }
        let session = DocumentSession(
            fileName: url.lastPathComponent,
            fileURL: url,
            pageCount: document.pageCount
        )
        store.upsert(session)
        sessions = store.sessions
        selectedSessionID = session.id
        return true
    }

    func openPDFs(at urls: [URL]) {
        for url in urls { openPDF(at: url) }
    }

    func closeSelectedPDF() {
        guard let id = selectedSessionID,
              let session = store.remove(id: id) else { return }
        sessions = store.sessions
        selectedSessionID = sessions.last?.id

        // Notify iPad
        if let client = activeClient {
            var close = Airpdf_V1_PdfClose()
            close.documentID = session.documentId
            client.send(.wrap(.pdfClose(close)))
        }
    }

    // MARK: - Server

    func startServer() {
        do {
            try server.start()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopServer() {
        server.stop()
    }

    // MARK: - Client events

    private var activeClient: ClientConnection?

    private func onClientConnected(_ client: ClientConnection) {
        activeClient = client
        client.onMessage = { [weak self] envelope in
            self?.handleMessage(envelope)
        }
        // Re-send PdfData for all open documents so iPad can restore session state
        // (Phase 2 will fill in actual PDF bytes; for Phase 1 we just send empty stubs)
        for session in store.sessions {
            var pdfData = Airpdf_V1_PdfData()
            pdfData.documentID = session.documentId
            pdfData.fileName = session.fileName
            pdfData.pageCount = UInt32(session.pageCount)
            client.send(.wrap(.pdfData(pdfData)))
        }
    }

    private func handleMessage(_ envelope: Airpdf_V1_SyncEnvelope) {
        // Phase 2+ will handle StrokeBatch, Undo, Redo, etc.
        switch envelope.payload.body {
        case .ping(let ping):
            var pong = Airpdf_V1_Pong()
            pong.sequence = ping.sequence
            activeClient?.send(.wrap(.pong(pong)))
        default:
            break
        }
    }
}
#endif
