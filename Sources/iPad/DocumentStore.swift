#if os(iOS)
import Foundation
import Combine
import CryptoKit
import PencilKit
import os

struct TabDocument: Identifiable, Equatable {
    let id: String          // documentId
    let fileName: String
    let pdfData: Data
    let pageCount: Int
    let pageDrawings: [Int: Data]
}

@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var documents: [TabDocument] = []

    private let logger = Logger(subsystem: "dev.airpdf.ipad", category: "DocumentStore")

    func receive(_ msg: Airpdf_V1_PdfData) {
        let computed = Data(SHA256.hash(data: msg.content))
        guard computed == msg.contentSha256 else {
            logger.error("SHA-256 mismatch for document \(msg.documentID) — discarding")
            return
        }
        logger.info("Storing document \(msg.documentID) (\(msg.fileName)), \(msg.content.count) bytes, \(msg.pageCount) pages")
        let drawings = msg.pageDrawings.reduce(into: [Int: Data]()) { $0[Int($1.key)] = $1.value }
        upsert(TabDocument(id: msg.documentID, fileName: msg.fileName, pdfData: msg.content,
                           pageCount: Int(msg.pageCount), pageDrawings: drawings))
    }

    /// Apply a drawings-only update from the Mac (e.g. undo/redo result for non-stroke actions).
    func applyDrawingsUpdate(_ msg: Airpdf_V1_DrawingsUpdate) {
        guard let idx = documents.firstIndex(where: { $0.id == msg.documentID }) else { return }
        var updated = documents[idx].pageDrawings
        for (k, v) in msg.pageDrawings { updated[Int(k)] = v }
        let old = documents[idx]
        upsert(TabDocument(id: old.id, fileName: old.fileName, pdfData: old.pdfData,
                           pageCount: old.pageCount, pageDrawings: updated))
    }

    func close(documentId: String) { documents.removeAll { $0.id == documentId } }
    func closeAll() { documents.removeAll() }

    private func upsert(_ doc: TabDocument) {
        if let idx = documents.firstIndex(where: { $0.id == doc.id }) {
            documents[idx] = doc
        } else {
            documents.append(doc)
        }
    }
}
#endif
