#if os(macOS)
import Foundation
import Combine
import PDFKit
import PencilKit
import CryptoKit
import SwiftUI
import SwiftProtobuf
import os

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [DocumentSession] = []
    @Published var selectedSessionID: UUID?
    @Published var lastError: String?
    @Published var fileConflictSession: DocumentSession?
    @Published var closeConfirmSession: DocumentSession?
    @Published var showOpenPanel = false

    let server = QuicServer()
    private let store = DocumentSessionStore()
    private let logger = Logger(subsystem: "dev.airpdf.mac", category: "AppModel")

    init() {
        server.onClientConnected = { [weak self] client in self?.onClientConnected(client) }
        server.onClientDisconnected = { [weak self] in self?.lastError = nil }
    }

    // MARK: - Documents

    @discardableResult
    func openPDF(at url: URL) -> Bool {
        if let existing = store.sessions.first(where: { $0.fileURL.standardizedFileURL == url.standardizedFileURL }) {
            selectedSessionID = existing.id
            return true
        }
        _ = url.startAccessingSecurityScopedResource()
        guard let document = PDFDocument(url: url) else {
            url.stopAccessingSecurityScopedResource()
            lastError = "Unable to open \(url.lastPathComponent)."
            return false
        }
        let session = DocumentSession(fileName: url.lastPathComponent, fileURL: url, pdfDocument: document)
        store.upsert(session)
        sessions = store.sessions
        selectedSessionID = session.id
        if let client = activeClient { client.send(.wrap(.pdfData(makePdfData(for: session)))) }
        session.startWatching { [weak self, weak session] in
            guard let self, let session else { return }
            self.handleExternalFileChange(session: session)
        }
        return true
    }

    func openPDFs(at urls: [URL]) { for url in urls { openPDF(at: url) } }

    func closeSelectedPDF() {
        guard let id = selectedSessionID,
              let session = store.sessions.first(where: { $0.id == id }) else { return }
        close(session: session)
    }

    func close(session: DocumentSession) {
        if session.hasUnsavedChanges { closeConfirmSession = session } else { forceClose(session: session) }
    }

    func forceClose(session: DocumentSession) { close(id: session.id) }

    private func close(id: UUID) {
        guard let session = store.remove(id: id) else { return }
        session.stopWatching()
        session.overlayCoordinator?.removeAllAnnotations()
        session.overlayCoordinator = nil
        session.pdfViewRef = nil
        session.fileURL.stopAccessingSecurityScopedResource()
        sessions = store.sessions
        if selectedSessionID == id { selectedSessionID = sessions.last?.id }
        if let client = activeClient {
            var msg = Airpdf_V1_PdfClose(); msg.documentID = session.documentId
            client.send(.wrap(.pdfClose(msg)))
        }
    }

    // MARK: - Builders

    private func makePdfData(for session: DocumentSession) -> Airpdf_V1_PdfData {
        let content = PDFStripper.strip(document: session.pdfDocument)
        var msg = Airpdf_V1_PdfData()
        msg.documentID = session.documentId
        msg.fileName = session.fileName
        msg.content = content
        msg.contentSha256 = Data(SHA256.hash(data: content))
        msg.pageCount = UInt32(session.pageCount)
        msg.pageStrokes = session.model.pageStrokesMap()
        return msg
    }

    private func makeDrawingsUpdate(for session: DocumentSession) -> Airpdf_V1_DrawingsUpdate {
        var msg = Airpdf_V1_DrawingsUpdate()
        msg.documentID = session.documentId
        msg.pageStrokes = session.model.pageStrokesMap()
        return msg
    }

    // MARK: - Server

    func startServer() { do { try server.start() } catch { lastError = error.localizedDescription } }
    func stopServer() { server.stop() }

    // MARK: - Client events

    private var activeClient: ClientConnection?

    private func onClientConnected(_ client: ClientConnection) {
        activeClient = client
        client.onMessage = { [weak self] envelope in self?.handleMessage(envelope) }
        for session in store.sessions { client.send(.wrap(.pdfData(makePdfData(for: session)))) }
    }

    private func handleMessage(_ envelope: Airpdf_V1_SyncEnvelope) {
        switch envelope.payload.body {
        case .strokeBatch(let msg):
            guard let session = store.sessions.first(where: { $0.documentId == msg.documentID }) else { return }
            let pageIdx = Int(msg.pageIndex)
            let entries: [(id: UUID, page: Int, stroke: PKStroke)] = msg.strokes.compactMap { entry in
                guard let uuid = UUID(uuidString: entry.strokeID),
                      let drawing = try? PKDrawing(data: entry.pkStrokeData),
                      let stroke = drawing.strokes.first else { return nil }
                return (id: uuid, page: pageIdx, stroke: stroke)
            }
            session.model.addStrokes(entries, changeID: msg.changeID.isEmpty ? nil : msg.changeID)
            for e in entries {
                session.overlayCoordinator?.addStrokeAnnotation(page: e.page, id: e.id.uuidString, stroke: e.stroke)
            }
            objectWillChange.send()

        case .strokeRemove(let msg):
            guard let session = store.sessions.first(where: { $0.documentId == msg.documentID }) else { return }
            let pageIdx = Int(msg.pageIndex)
            let removeSet = Set(msg.strokeIds)
            session.model.removeStrokes(
                ids: Set(removeSet.compactMap { UUID(uuidString: $0) }),
                changeID: msg.changeID.isEmpty ? nil : msg.changeID
            )
            session.overlayCoordinator?.removeStrokeAnnotations(page: pageIdx, ids: removeSet)
            objectWillChange.send()

        case .undo(let msg):
            guard let session = store.sessions.first(where: { $0.documentId == msg.documentID }) else { return }
            handleUndo(session: session); objectWillChange.send()

        case .redo(let msg):
            guard let session = store.sessions.first(where: { $0.documentId == msg.documentID }) else { return }
            handleRedo(session: session); objectWillChange.send()

        default: break
        }
    }

    func handleUndo(session: DocumentSession) {
        guard session.model.undo() != nil else { return }
        session.overlayCoordinator?.rebuildAnnotations()
        activeClient?.send(.wrap(.drawingsUpdate(makeDrawingsUpdate(for: session))))
    }

    func handleRedo(session: DocumentSession) {
        guard session.model.redo() != nil else { return }
        session.overlayCoordinator?.rebuildAnnotations()
        activeClient?.send(.wrap(.drawingsUpdate(makeDrawingsUpdate(for: session))))
    }

    // MARK: - External file change

    private func handleExternalFileChange(session: DocumentSession) {
        if session.hasUnsavedChanges {
            session.hasExternalConflict = true
            fileConflictSession = session
        } else {
            reloadFromDisk(session: session)
        }
    }

    func reloadFromDisk(session: DocumentSession) {
        session.stopWatching()
        session.hasExternalConflict = false
        fileConflictSession = nil
        guard let newDoc = PDFDocument(url: session.fileURL) else { return }
        session.reloadFromDisk(pdfDocument: newDoc)
        session.pdfViewRef?.document = newDoc
        session.overlayCoordinator?.rebuildAnnotations()
        if let client = activeClient { client.send(.wrap(.pdfData(makePdfData(for: session)))) }
        session.startWatching { [weak self, weak session] in
            guard let self, let session else { return }
            self.handleExternalFileChange(session: session)
        }
    }

    func keepInMemory(session: DocumentSession) {
        session.hasExternalConflict = false
        fileConflictSession = nil
    }

    // MARK: - Save

    func saveSelectedPDF() {
        guard let id = selectedSessionID,
              let session = sessions.first(where: { $0.id == id }) else { return }
        session.stopWatching()
        session.overlayCoordinator?.removeAllAnnotations()

        let byPage = session.model.allActiveStrokes()

        for i in 0..<session.pageCount {
            guard let page = session.pdfDocument.page(at: i) else { continue }
            page.annotations
                .filter { ($0.type == "FileAttachment" && ($0.contents == "airpdf_strokes.pb" || $0.contents == "airpdf_drawing.pkdata")) || $0.type == "Stamp" }
                .forEach { page.removeAnnotation($0) }

            guard let strokes = byPage[i], !strokes.isEmpty else { continue }

            var ps = Airpdf_V1_PageStrokes()
            for (uuid, stroke) in strokes {
                var se = Airpdf_V1_StrokeEntry()
                se.strokeID = uuid.uuidString
                se.pkStrokeData = (try? PKDrawing(strokes: [stroke]).dataRepresentation()) ?? Data()
                ps.strokes.append(se)
            }
            if let pbData = try? ps.serializedData() {
                let att = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                        forType: PDFAnnotationSubtype(rawValue: "/FileAttachment"), withProperties: nil)
                att.contents = "airpdf_strokes.pb"
                att.setValue(pbData, forAnnotationKey: PDFAnnotationKey(rawValue: "/FS"))
                page.addAnnotation(att)
            }

            for (_, stroke) in strokes {
                if let ann = StrokeAnnotationLayer.makeSaveAnnotation(stroke: stroke, page: page) {
                    page.addAnnotation(ann)
                }
            }
        }

        guard let pdfData = session.pdfDocument.dataRepresentation() else {
            session.overlayCoordinator?.rebuildAnnotations()
            session.startWatching { [weak self, weak session] in
                guard let self, let session else { return }
                self.handleExternalFileChange(session: session)
            }
            return
        }
        do {
            try pdfData.write(to: session.fileURL, options: .atomic)
            session.model.markSaved()
            objectWillChange.send()
            logger.info("saveSelectedPDF: success → \(session.fileURL.path)")
        } catch {
            logger.error("saveSelectedPDF: write failed: \(error)")
        }

        for i in 0..<session.pdfDocument.pageCount {
            guard let page = session.pdfDocument.page(at: i) else { continue }
            page.annotations.filter { $0.type == "Stamp" }.forEach { page.removeAnnotation($0) }
        }
        session.overlayCoordinator?.rebuildAnnotations()
        session.startWatching { [weak self, weak session] in
            guard let self, let session else { return }
            self.handleExternalFileChange(session: session)
        }
    }
}
#endif
