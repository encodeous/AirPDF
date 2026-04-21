#if os(macOS)
import Foundation
import Combine
import PDFKit
import PencilKit
import CryptoKit
import SwiftUI
import os

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [DocumentSession] = []
    @Published var selectedSessionID: UUID?
    @Published var lastError: String?
    /// Session with a detected external file conflict (prompt user to reload or keep).
    @Published var fileConflictSession: DocumentSession?
    @Published var showOpenPanel = false

    let server = QuicServer()
    private let store = DocumentSessionStore()
    private let logger = Logger(subsystem: "dev.airpdf.mac", category: "AppModel")

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
        // Watch for external file changes
        session.startWatching { [weak self, weak session] in
            guard let self, let session else { return }
            self.handleExternalFileChange(session: session)
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

    private func makeDrawingsUpdate(for session: DocumentSession) -> Airpdf_V1_DrawingsUpdate {
        var msg = Airpdf_V1_DrawingsUpdate()
        msg.documentID = session.documentId
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
            // Truncate any redo history above the cursor
            session.strokeLog.removeSubrange(session.undoIndex...)
            for entry in msg.strokes {
                guard let drawing = try? PKDrawing(data: entry.pkStrokeData),
                      let stroke = drawing.strokes.first else { continue }
                session.strokeLog.append((id: entry.strokeID, page: pageIdx, stroke: stroke))
                session.undoIndex += 1
                // Add annotation for the new stroke
                session.overlayCoordinator?.addStrokeAnnotation(page: pageIdx, id: entry.strokeID, stroke: stroke)
            }
            rebuildDrawing(session: session, page: pageIdx)
            objectWillChange.send()

        case .strokeRemove(let msg):
            guard let session = store.sessions.first(where: { $0.documentId == msg.documentID }) else { return }
            let pageIdx = Int(msg.pageIndex)
            let removeSet = Set(msg.strokeIds)
            // Remove matching entries from the log entirely (erase is permanent, not undoable here)
            session.strokeLog.removeAll { removeSet.contains($0.id) }
            session.undoIndex = min(session.undoIndex, session.strokeLog.count)
            session.overlayCoordinator?.removeStrokeAnnotations(page: pageIdx, ids: removeSet)
            rebuildDrawing(session: session, page: pageIdx)
            objectWillChange.send()

        case .undo(let msg):
            guard let session = store.sessions.first(where: { $0.documentId == msg.documentID }) else { return }
            handleUndo(session: session)
            objectWillChange.send()

        case .redo(let msg):
            guard let session = store.sessions.first(where: { $0.documentId == msg.documentID }) else { return }
            handleRedo(session: session)
            objectWillChange.send()

        default: break
        }
    }

    /// Rebuild pageDrawings[page] from the active portion of strokeLog (0..<undoIndex).
    private func rebuildDrawing(session: DocumentSession, page: Int) {
        let strokes = session.strokeLog[0..<session.undoIndex]
            .filter { $0.page == page }
            .map { $0.stroke }
        updateDrawing(session: session, page: page, strokes: strokes)
    }

    func handleUndo(session: DocumentSession) {
        guard session.undoIndex > 0 else { return }
        session.undoIndex -= 1
        let entry = session.strokeLog[session.undoIndex]
        session.overlayCoordinator?.removeStrokeAnnotations(page: entry.page, ids: [entry.id])
        rebuildDrawing(session: session, page: entry.page)
        var remove = Airpdf_V1_StrokeRemove()
        remove.documentID = session.documentId
        remove.pageIndex = UInt32(entry.page)
        remove.strokeIds = [entry.id]
        activeClient?.send(.wrap(.strokeRemove(remove)))
        activeClient?.send(.wrap(.drawingsUpdate(makeDrawingsUpdate(for: session))))
    }

    func handleRedo(session: DocumentSession) {
        guard session.undoIndex < session.strokeLog.count else { return }
        let entry = session.strokeLog[session.undoIndex]
        session.undoIndex += 1
        session.overlayCoordinator?.addStrokeAnnotation(page: entry.page, id: entry.id, stroke: entry.stroke)
        rebuildDrawing(session: session, page: entry.page)
        var batch = Airpdf_V1_StrokeBatch()
        batch.documentID = session.documentId
        batch.pageIndex = UInt32(entry.page)
        var e = Airpdf_V1_StrokeEntry()
        e.strokeID = entry.id
        e.pkStrokeData = (try? PKDrawing(strokes: [entry.stroke]).dataRepresentation()) ?? Data()
        batch.strokes = [e]
        activeClient?.send(.wrap(.strokeBatch(batch)))
        activeClient?.send(.wrap(.drawingsUpdate(makeDrawingsUpdate(for: session))))
    }

    private func updateDrawing(session: DocumentSession, page: Int, strokes: [PKStroke]) {
        let baseStrokes = session.baseDrawings[page]?.strokes ?? []
        let drawing = PKDrawing(strokes: baseStrokes + strokes)
        session.pageDrawings[page] = (try? drawing.dataRepresentation()) ?? Data()
        session.overlayCoordinator?.refreshOverlays()
        logger.info("updateDrawing: page \(page), \(strokes.count) strokes")
    }

    // MARK: - External file change

    private func handleExternalFileChange(session: DocumentSession) {
        if session.undoIndex > 0 {
            session.hasExternalConflict = true
            fileConflictSession = session
        } else {
            reloadFromDisk(session: session)
        }
    }

    /// Reload the document from disk, discarding in-memory changes.
    func reloadFromDisk(session: DocumentSession) {
        session.stopWatching()
        session.hasExternalConflict = false
        fileConflictSession = nil
        guard let newDoc = PDFDocument(url: session.fileURL) else { return }
        // Reload pkdata from new file
        var drawings: [Int: Data] = [:]
        for i in 0..<newDoc.pageCount {
            guard let page = newDoc.page(at: i) else { continue }
            for ann in page.annotations {
                guard ann.type == "FileAttachment",
                      ann.contents == "airpdf_drawing.pkdata",
                      let data = ann.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/FS")) as? Data
                else { continue }
                drawings[i] = data
            }
        }
        session.pageDrawings = drawings
        session.baseDrawings = drawings.compactMapValues { try? PKDrawing(data: $0) }
        session.strokeLog = []
        session.undoIndex = 0
        session.savedUndoIndex = 0
        session.pdfViewRef?.document = newDoc
        session.overlayCoordinator?.rebuildAnnotations()
        // Re-send to iPad
        if let client = activeClient {
            client.send(.wrap(.pdfData(makePdfData(for: session))))
        }
        session.startWatching { [weak self, weak session] in
            guard let self, let session else { return }
            self.handleExternalFileChange(session: session)
        }
    }

    /// Keep in-memory version; next save will overwrite the file.
    func keepInMemory(session: DocumentSession) {
        session.hasExternalConflict = false
        fileConflictSession = nil
    }

    // MARK: - Save

    func saveSelectedPDF() {
        guard let id = selectedSessionID,
              let session = sessions.first(where: { $0.id == id }) else { return }
        session.stopWatching()
        // Remove live-preview annotations (managed by StrokeAnnotationLayer)
        session.overlayCoordinator?.removeAllAnnotations()
        // Attach pkdata + visible stamp per page
        for (pageIdx, drawingData) in session.pageDrawings {
            guard let page = session.pdfDocument.page(at: pageIdx) else { continue }
            // Remove old AirPDF annotations (pkdata + any leftover stamps)
            page.annotations
                .filter {
                    ($0.type == "FileAttachment" && $0.contents == "airpdf_drawing.pkdata") ||
                    $0.type == "Stamp"
                }
                .forEach { page.removeAnnotation($0) }
            // Hidden pkdata attachment (round-trip fidelity)
            let att = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    forType: PDFAnnotationSubtype(rawValue: "/FileAttachment"),
                                    withProperties: nil)
            att.contents = "airpdf_drawing.pkdata"
            att.setValue(drawingData, forAnnotationKey: PDFAnnotationKey(rawValue: "/FS"))
            page.addAnnotation(att)
            // Visible stamp annotations (printable) — one per stroke, same path as live preview
            if let drawing = try? PKDrawing(data: drawingData) {
                for stroke in drawing.strokes {
                    if let ann = StrokeAnnotationLayer.makeSaveAnnotation(stroke: stroke, page: page) {
                        page.addAnnotation(ann)
                    }
                }
            }
        }
        // Write PDF data
        guard let pdfData = session.pdfDocument.dataRepresentation() else {
            logger.error("saveSelectedPDF: dataRepresentation() returned nil")
            session.overlayCoordinator?.rebuildAnnotations()
            session.startWatching { [weak self, weak session] in
                guard let self, let session else { return }
                self.handleExternalFileChange(session: session)
            }
            return
        }
        do {
            try pdfData.write(to: session.fileURL, options: .atomic)
            session.savedUndoIndex = session.undoIndex
            logger.info("saveSelectedPDF: success → \(session.fileURL.path)")
        } catch {
            logger.error("saveSelectedPDF: write failed: \(error)")
        }
        // Remove save-time stamps (they're in the file now) and restore live annotations
        for i in 0..<session.pdfDocument.pageCount {
            guard let page = session.pdfDocument.page(at: i) else { continue }
            page.annotations
                .filter { $0.type == "Stamp" }
                .forEach { page.removeAnnotation($0) }
        }
        session.overlayCoordinator?.rebuildAnnotations()
        session.startWatching { [weak self, weak session] in
            guard let self, let session else { return }
            self.handleExternalFileChange(session: session)
        }
    }
}
#endif
