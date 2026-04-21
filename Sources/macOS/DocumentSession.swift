#if os(macOS)
import Foundation
import PDFKit
import PencilKit
import SwiftProtobuf

final class DocumentSession: Identifiable, @unchecked Sendable {
    let id: UUID           // local SwiftUI identity
    let documentId: String // AirPDF protocol document_id sent to iPad
    let fileName: String
    let fileURL: URL
    let pageCount: Int
    let pdfDocument: PDFDocument
    /// Ordered log of all strokes. Active = strokeLog[0..<undoIndex].
    var strokeLog: [(id: UUID, page: Int, stroke: PKStroke)] = []
    var undoIndex: Int = 0
    var savedUndoIndex: Int = 0
    var hasUnsavedChanges: Bool { undoIndex != savedUndoIndex }
    weak var pdfViewRef: PDFView?
    weak var overlayCoordinator: MacAnnotationCoordinator?
    var hasExternalConflict = false
    private var fileWatchSource: DispatchSourceFileSystemObject?

    init(fileName: String, fileURL: URL, pdfDocument: PDFDocument) {
        self.id = UUID()
        self.documentId = UUID().uuidString
        self.fileName = fileName
        self.fileURL = fileURL
        self.pageCount = pdfDocument.pageCount
        self.pdfDocument = pdfDocument
        loadStrokesFromDisk(pdfDocument: pdfDocument)
        savedUndoIndex = undoIndex
    }

    /// Load strokes from airpdf_strokes.pb attachments into strokeLog.
    func loadStrokesFromDisk(pdfDocument: PDFDocument) {
        strokeLog = []
        for i in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: i) else { continue }
            var toRemove: [PDFAnnotation] = []
            for ann in page.annotations {
                if ann.type == "FileAttachment" && (ann.contents == "airpdf_strokes.pb" || ann.contents == "airpdf_drawing.pkdata") {
                    if ann.contents == "airpdf_strokes.pb",
                       let data = ann.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/FS")) as? Data,
                       let pageStrokes = try? Airpdf_V1_PageStrokes(serializedBytes: data) {
                        for entry in pageStrokes.strokes {
                            guard let uuid = UUID(uuidString: entry.strokeID),
                                  let drawing = try? PKDrawing(data: entry.pkStrokeData),
                                  let stroke = drawing.strokes.first else { continue }
                            strokeLog.append((id: uuid, page: i, stroke: stroke))
                        }
                    }
                    toRemove.append(ann)
                } else if ann.type == "Stamp" {
                    toRemove.append(ann)
                }
            }
            toRemove.forEach { page.removeAnnotation($0) }
        }
        undoIndex = strokeLog.count
    }

    func startWatching(onChange: @escaping () -> Void) {
        stopWatching()
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatchSource = source
    }

    func stopWatching() {
        fileWatchSource?.cancel()
        fileWatchSource = nil
    }

    deinit { stopWatching() }
}

extension DocumentSession: Equatable {
    static func == (lhs: DocumentSession, rhs: DocumentSession) -> Bool { lhs.id == rhs.id }
}
#endif
