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
    /// Base drawings loaded from disk (immutable after init/reload). Used to merge with strokeLog.
    var baseDrawings: [Int: PKDrawing] = [:]
    /// Ordered log of all strokes received. undoIndex is the cursor into this log.
    /// Active strokes = strokeLog[0..<undoIndex]. Undo decrements, redo increments.
    var strokeLog: [(id: String, page: Int, stroke: PKStroke)] = []
    var undoIndex: Int = 0
    var needsDisplayUpdate = false
    weak var pdfViewRef: PDFView?
    weak var overlayCoordinator: MacOverlayCoordinator?

    /// Set to true when an external file change is detected while there are unsaved in-memory changes.
    var hasExternalConflict = false

    private var fileWatchSource: DispatchSourceFileSystemObject?

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
        // Cache base drawings for merging with strokeLog
        var base: [Int: PKDrawing] = [:]
        for (idx, data) in drawings {
            if let d = try? PKDrawing(data: data) { base[idx] = d }
        }
        self.baseDrawings = base
    }

    /// Start watching the file for external changes. Calls `onChange` on the main queue.
    func startWatching(onChange: @escaping () -> Void) {
        stopWatching()
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
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
