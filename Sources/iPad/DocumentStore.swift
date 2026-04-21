#if os(iOS)
import Foundation
import Combine
import CryptoKit
import os

struct TabDocument: Identifiable, Equatable, Hashable {
    let id: String
    let fileName: String
    let pdfData: Data
    let pageCount: Int
    /// Raw proto page_strokes for initial load. Not used for identity.
    let pageStrokesProto: [UInt32: Airpdf_V1_PageStrokes]

    static func == (lhs: TabDocument, rhs: TabDocument) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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
        upsert(TabDocument(id: msg.documentID, fileName: msg.fileName, pdfData: msg.content,
                           pageCount: Int(msg.pageCount), pageStrokesProto: msg.pageStrokes))
    }

    func close(documentId: String) { documents.removeAll { $0.id == documentId } }
    func closeAll() { documents.removeAll() }

    private func upsert(_ doc: TabDocument) {
        if let idx = documents.firstIndex(where: { $0.id == doc.id }) { documents[idx] = doc }
        else { documents.append(doc) }
    }
}
#endif
