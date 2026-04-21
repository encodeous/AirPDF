#if os(iOS)
import Foundation
import Combine
import CryptoKit
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
        // Integrity check
        let computed = Data(SHA256.hash(data: msg.content))
        guard computed == msg.contentSha256 else {
            logger.error("SHA-256 mismatch for document \(msg.documentID) — discarding")
            return
        }
        logger.info("Storing document \(msg.documentID) (\(msg.fileName)), \(msg.content.count) bytes, \(msg.pageCount) pages")
        let drawings = msg.pageDrawings.reduce(into: [Int: Data]()) { $0[Int($1.key)] = $1.value }
        let doc = TabDocument(
            id: msg.documentID,
            fileName: msg.fileName,
            pdfData: msg.content,
            pageCount: Int(msg.pageCount),
            pageDrawings: drawings
        )
        if let idx = documents.firstIndex(where: { $0.id == msg.documentID }) {
            documents[idx] = doc
        } else {
            documents.append(doc)
        }
    }

    func close(documentId: String) {
        documents.removeAll { $0.id == documentId }
    }

    func closeAll() {
        documents.removeAll()
    }
}
#endif
