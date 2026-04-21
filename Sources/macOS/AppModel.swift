#if os(macOS)
import Foundation
import Combine
import PDFKit
import CryptoKit
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
        _ = url.startAccessingSecurityScopedResource()
        guard let document = PDFDocument(url: url) else {
            url.stopAccessingSecurityScopedResource()
            lastError = "Unable to open \(url.lastPathComponent)."
            return false
        }
        let session = DocumentSession(
            fileName: url.lastPathComponent,
            fileURL: url,
            pdfDocument: document
        )
        store.upsert(session)
        sessions = store.sessions
        selectedSessionID = session.id
        // Push to connected iPad immediately
        if let client = activeClient {
            client.send(.wrap(.pdfData(makePdfData(for: session))))
        }
        return true
    }

    func openPDFs(at urls: [URL]) {
        for url in urls { openPDF(at: url) }
    }

    func closeSelectedPDF() {
        guard let id = selectedSessionID else { return }
        close(id: id)
    }

    func close(session: DocumentSession) {
        close(id: session.id)
    }

    private func close(id: UUID) {
        guard let session = store.remove(id: id) else { return }
        session.fileURL.stopAccessingSecurityScopedResource()
        sessions = store.sessions
        if selectedSessionID == id {
            selectedSessionID = sessions.last?.id
        }
        if let client = activeClient {
            var close = Airpdf_V1_PdfClose()
            close.documentID = session.documentId
            client.send(.wrap(.pdfClose(close)))
        }
    }

    // MARK: - PdfData builder

    private func makePdfData(for session: DocumentSession) -> Airpdf_V1_PdfData {
        let content = PDFStripper.strip(document: session.pdfDocument)
        let digest = SHA256.hash(data: content)
        var msg = Airpdf_V1_PdfData()
        msg.documentID = session.documentId
        msg.fileName = session.fileName
        msg.content = content
        msg.contentSha256 = Data(digest)
        msg.pageCount = UInt32(session.pageCount)
        msg.pageDrawings = session.pageDrawings.reduce(into: [:]) { $0[UInt32($1.key)] = $1.value }
        return msg
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
        // Re-send PdfData for all open documents
        for session in store.sessions {
            client.send(.wrap(.pdfData(makePdfData(for: session))))
        }
    }

    private func handleMessage(_ envelope: Airpdf_V1_SyncEnvelope) {
        // Phase 3+ will handle StrokeBatch, Undo, Redo, etc.
    }
}
#endif
