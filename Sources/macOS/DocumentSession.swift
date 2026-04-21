#if os(macOS)
import Foundation
import PDFKit
import PencilKit

final class DocumentSession: Identifiable, @unchecked Sendable {
    let id: UUID           // local SwiftUI identity
    let documentId: String // AirPDF protocol document_id sent to iPad
    let fileName: String
    let fileURL: URL
    let pageCount: Int
    let pdfDocument: PDFDocument
    var pageDrawings: [Int: Data]       // page index → PKDrawing.dataRepresentation()
    var strokeMetadata: [Int: [String: PKStroke]] = [:] // page → strokeId → PKStroke
    let undoManager = UndoManager()
    var needsDisplayUpdate = false
    weak var pdfViewRef: PDFView?
    weak var overlayCoordinator: MacOverlayCoordinator?

    init(fileName: String, fileURL: URL, pdfDocument: PDFDocument) {
        self.id = UUID()
        self.documentId = UUID().uuidString
        self.fileName = fileName
        self.fileURL = fileURL
        self.pageCount = pdfDocument.pageCount
        self.pdfDocument = pdfDocument
        var drawings: [Int: Data] = [:]
        for i in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: i) else { continue }
            for ann in page.annotations {
                guard ann.type == "FileAttachment",
                      ann.contents == "airpdf_drawing.pkdata",
                      let data = ann.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/FS")) as? Data
                else { continue }
                drawings[i] = data
            }
        }
        self.pageDrawings = drawings
    }
}

extension DocumentSession: Equatable {
    static func == (lhs: DocumentSession, rhs: DocumentSession) -> Bool { lhs.id == rhs.id }
}
#endif
