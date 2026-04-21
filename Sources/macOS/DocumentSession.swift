#if os(macOS)
import Foundation
import PDFKit

final class DocumentSession: Identifiable, @unchecked Sendable {
    let id: UUID           // local SwiftUI identity
    let documentId: String // AirPDF protocol document_id sent to iPad
    let fileName: String
    let fileURL: URL
    let pageCount: Int
    let pdfDocument: PDFDocument
    var pageDrawings: [Int: Data] // page index → PKDrawing.dataRepresentation()

    init(fileName: String, fileURL: URL, pdfDocument: PDFDocument) {
        self.id = UUID()
        self.documentId = UUID().uuidString
        self.fileName = fileName
        self.fileURL = fileURL
        self.pageCount = pdfDocument.pageCount
        self.pdfDocument = pdfDocument
        self.pageDrawings = [:]
    }
}

extension DocumentSession: Equatable {
    static func == (lhs: DocumentSession, rhs: DocumentSession) -> Bool { lhs.id == rhs.id }
}
#endif
