import Foundation
import PDFKit

/// Prepares a PDFDocument for transmission to the iPad.
/// Phase 2: no-op — returns raw PDF bytes.
/// Phase 3: will strip stroke outline annotations and airpdf_drawing.pkdata attachments.
enum PDFStripper {
    static func strip(document: PDFDocument) -> Data {
        document.dataRepresentation() ?? Data()
    }
}
