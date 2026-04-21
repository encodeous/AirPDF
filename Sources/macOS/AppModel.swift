#if os(macOS)
import Foundation
import Combine
import PDFKit
import PencilKit
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
        switch envelope.payload.body {
        case .strokeBatch(let msg):
            guard let session = store.sessions.first(where: { $0.documentId == msg.documentID }) else { return }
            let pageIdx = Int(msg.pageIndex)
            let prevStrokes = currentStrokes(session: session, page: pageIdx)
            let prevMeta = session.strokeMetadata[pageIdx] ?? [:]
            var strokes = prevStrokes
            var addedIds: [String] = []
            for entry in msg.strokes {
                guard let drawing = try? PKDrawing(data: entry.pkStrokeData),
                      let stroke = drawing.strokes.first else { continue }
                strokes.append(stroke)
                session.strokeMetadata[pageIdx, default: [:]][entry.strokeID] = stroke
                addedIds.append(entry.strokeID)
            }
            updateDrawing(session: session, page: pageIdx, strokes: strokes)
            // Register undo
            session.undoManager.registerUndo(withTarget: self) { [weak self] target in
                guard let self else { return }
                addedIds.forEach { session.strokeMetadata[pageIdx]?.removeValue(forKey: $0) }
                self.updateDrawing(session: session, page: pageIdx, strokes: prevStrokes)
                // Send StrokeRemove to iPad for each undone stroke
                for sid in addedIds {
                    var remove = Airpdf_V1_StrokeRemove()
                    remove.documentID = msg.documentID
                    remove.pageIndex = msg.pageIndex
                    remove.strokeID = sid
                    self.activeClient?.send(.wrap(.strokeRemove(remove)))
                }
                self.objectWillChange.send()
            }
            objectWillChange.send()

        case .strokeRemove(let msg):
            guard let session = store.sessions.first(where: { $0.documentId == msg.documentID }) else { return }
            let pageIdx = Int(msg.pageIndex)
            session.strokeMetadata[pageIdx]?.removeValue(forKey: msg.strokeID)
            let remaining = Array((session.strokeMetadata[pageIdx] ?? [:]).values)
            updateDrawing(session: session, page: pageIdx, strokes: remaining)
            objectWillChange.send()

        case .undo(let msg):
            guard let session = store.sessions.first(where: { $0.documentId == msg.documentID }) else { return }
            session.undoManager.undo()
            objectWillChange.send()

        case .redo(let msg):
            guard let session = store.sessions.first(where: { $0.documentId == msg.documentID }) else { return }
            session.undoManager.redo()
            objectWillChange.send()

        default: break
        }
    }

    private func currentStrokes(session: DocumentSession, page: Int) -> [PKStroke] {
        guard let data = session.pageDrawings[page],
              let drawing = try? PKDrawing(data: data) else { return [] }
        return drawing.strokes
    }

    private func updateDrawing(session: DocumentSession, page: Int, strokes: [PKStroke]) {
        let drawing = PKDrawing(strokes: strokes)
        session.pageDrawings[page] = (try? drawing.dataRepresentation()) ?? Data()
        // Render strokes as ink annotations on the PDFPage for Mac display
        guard let pdfPage = session.pdfDocument.page(at: page) else { return }
        // Remove existing AirPDF ink annotations
        pdfPage.annotations.filter { $0.type == "Ink" }.forEach { pdfPage.removeAnnotation($0) }
        // Add one ink annotation per stroke
        for stroke in strokes {
            let ann = PKStroke.toPDFInkAnnotation(stroke, page: pdfPage)
            pdfPage.addAnnotation(ann)
        }
    }

    // MARK: - Save

    func saveSelectedPDF() {
        guard let id = selectedSessionID,
              let session = sessions.first(where: { $0.id == id }) else { return }
        // Attach pkdata per page
        for (pageIdx, drawingData) in session.pageDrawings {
            guard let page = session.pdfDocument.page(at: pageIdx) else { continue }
            // Remove old pkdata attachment
            page.annotations
                .filter { $0.type == "FileAttachment" && $0.contents == "airpdf_drawing.pkdata" }
                .forEach { page.removeAnnotation($0) }
            // Add new pkdata attachment
            let ann = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    forType: PDFAnnotationSubtype(rawValue: "/FileAttachment"),
                                    withProperties: nil)
            ann.contents = "airpdf_drawing.pkdata"
            ann.setValue(drawingData, forAnnotationKey: PDFAnnotationKey(rawValue: "/FS"))
            page.addAnnotation(ann)
        }
        session.pdfDocument.write(to: session.fileURL)
    }
}
#endif
