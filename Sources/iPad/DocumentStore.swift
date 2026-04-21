#if os(iOS)
import Foundation
import Combine
import CryptoKit
import PencilKit
import os

struct TabDocument: Identifiable {
    let id: String
    let fileName: String
    let pdfData: Data
    let pageCount: Int
    let pageStrokes: [Int: [(id: UUID, stroke: PKStroke)]]
}

extension TabDocument: Equatable {
    static func == (lhs: TabDocument, rhs: TabDocument) -> Bool {
        guard lhs.id == rhs.id && lhs.pageStrokes.count == rhs.pageStrokes.count else { return false }
        for (page, lStrokes) in lhs.pageStrokes {
            guard let rStrokes = rhs.pageStrokes[page], lStrokes.map(\.id) == rStrokes.map(\.id) else { return false }
        }
        return true
    }
}

extension TabDocument: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        for (page, strokes) in pageStrokes.sorted(by: { $0.key < $1.key }) {
            hasher.combine(page)
            strokes.forEach { hasher.combine($0.id) }
        }
    }
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
                           pageCount: Int(msg.pageCount), pageStrokes: decodePageStrokes(msg.pageStrokes)))
    }

    func applyDrawingsUpdate(_ msg: Airpdf_V1_DrawingsUpdate) {
        guard let idx = documents.firstIndex(where: { $0.id == msg.documentID }) else { return }
        var updated = documents[idx].pageStrokes
        for (k, v) in decodePageStrokes(msg.pageStrokes) { updated[k] = v }
        let old = documents[idx]
        upsert(TabDocument(id: old.id, fileName: old.fileName, pdfData: old.pdfData,
                           pageCount: old.pageCount, pageStrokes: updated))
    }

    func close(documentId: String) { documents.removeAll { $0.id == documentId } }
    func closeAll() { documents.removeAll() }

    private func upsert(_ doc: TabDocument) {
        if let idx = documents.firstIndex(where: { $0.id == doc.id }) { documents[idx] = doc }
        else { documents.append(doc) }
    }

    private func decodePageStrokes(_ map: [UInt32: Airpdf_V1_PageStrokes]) -> [Int: [(id: UUID, stroke: PKStroke)]] {
        map.compactMapValues { ps in
            let pairs: [(id: UUID, stroke: PKStroke)] = ps.strokes.compactMap { entry in
                guard let uuid = UUID(uuidString: entry.strokeID),
                      let drawing = try? PKDrawing(data: entry.pkStrokeData),
                      let stroke = drawing.strokes.first else { return nil }
                return (id: uuid, stroke: stroke)
            }
            return pairs.isEmpty ? nil : pairs
        }.reduce(into: [:]) { $0[Int($1.key)] = $1.value }
    }
}
#endif
