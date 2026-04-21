#if os(macOS)
import Foundation
import PDFKit
import PencilKit

final class DocumentSession: Identifiable, @unchecked Sendable {
    let id: UUID
    let documentId: String
    let fileName: String
    let fileURL: URL
    let pageCount: Int
    let pdfDocument: PDFDocument
    let model = StrokeModel()
    weak var pdfViewRef: PDFView?
    weak var overlayCoordinator: MacAnnotationCoordinator?
    var hasExternalConflict = false
    private var fileWatchSource: DispatchSourceFileSystemObject?

    var hasUnsavedChanges: Bool { model.hasUnsavedChanges }

    init(fileName: String, fileURL: URL, pdfDocument: PDFDocument) {
        self.id = UUID()
        self.documentId = UUID().uuidString
        self.fileName = fileName
        self.fileURL = fileURL
        self.pageCount = pdfDocument.pageCount
        self.pdfDocument = pdfDocument
        model.loadFromDisk(pdfDocument: pdfDocument)
        model.markSaved()
    }

    func reloadFromDisk(pdfDocument: PDFDocument) {
        model.loadFromDisk(pdfDocument: pdfDocument)
        model.markSaved()
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
