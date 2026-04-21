import Foundation
import PDFKit

enum PDFStripper {
    static func strip(document: PDFDocument) -> Data {
        guard let copy = document.copy() as? PDFDocument else {
            return document.dataRepresentation() ?? Data()
        }
        for i in 0..<copy.pageCount {
            guard let page = copy.page(at: i) else { continue }
            let toRemove = page.annotations.filter {
                $0.type == "Ink" ||
                ($0.type == "FileAttachment" && $0.contents == "airpdf_drawing.pkdata")
            }
            toRemove.forEach { page.removeAnnotation($0) }
        }
        return copy.dataRepresentation() ?? Data()
    }
}
