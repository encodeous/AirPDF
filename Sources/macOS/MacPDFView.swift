#if os(macOS)
import SwiftUI
import PDFKit
import PencilKit

struct MacPDFView: NSViewRepresentable {
    let document: PDFDocument
    let session: DocumentSession

    func makeCoordinator() -> MacAnnotationCoordinator {
        MacAnnotationCoordinator(session: session)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        session.pdfViewRef = view
        session.overlayCoordinator = context.coordinator
        // Rebuild annotations now that coordinator is wired — disk strokes are already in strokeLog.
        context.coordinator.rebuildAnnotations()
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
            session.pdfViewRef = nsView
        }
    }
}

/// Manages per-page 8× stamp annotations on the Mac PDF viewer.
/// No overlay needed — annotations are the sole display layer.
final class MacAnnotationCoordinator: NSObject {
    let session: DocumentSession
    private var annotationLayers: [Int: StrokeAnnotationLayer] = [:]

    init(session: DocumentSession) {
        self.session = session
    }

    /// Add a stroke as an annotation on the given page.
    func addStrokeAnnotation(page: Int, id: String, stroke: PKStroke) {
        guard let layer = annotationLayer(for: page) else { return }
        layer.addStroke(id: id, stroke: stroke)
    }

    /// Remove stroke annotations by ID. Uses page re-insert to force visual refresh
    /// (Apple removeAnnotation display bug), with scroll position preserved.
    func removeStrokeAnnotations(page pageIdx: Int, ids: Set<String>) {
        let hadLayer = annotationLayers[pageIdx] != nil
        annotationLayers[pageIdx]?.removeStrokes(ids: ids)
        NSLog("removeStrokeAnnotations page \(pageIdx): ids=\(ids) hadLayer=\(hadLayer) layerCount=\(annotationLayers[pageIdx]?.strokeIds.count ?? -1)")
        invalidatePage(pageIdx)
    }

    /// Remove all live annotations (e.g. before save).
    func removeAllAnnotations() {
        for layer in annotationLayers.values { layer.removeAll() }
        annotationLayers.removeAll()
    }

    /// Rebuild all annotations from the session's strokeLog. Called after save or reload.
    func rebuildAnnotations() {
        removeAllAnnotations()
        for pageIdx in 0..<session.pageCount {
            rebuildAnnotationsForPage(pageIdx)
            invalidatePage(pageIdx)
        }
    }

    /// No-op — kept for compatibility with existing callsites.
    func refreshOverlays() {}

    // MARK: - Private

    private func rebuildAnnotationsForPage(_ pageIdx: Int) {
        guard let layer = annotationLayer(for: pageIdx) else { return }
        for entry in session.strokeLog[0..<session.undoIndex] where entry.page == pageIdx {
            if !layer.strokeIds.contains(entry.id.uuidString) {
                layer.addStroke(id: entry.id.uuidString, stroke: entry.stroke)
            }
        }
    }

    /// Force PDFKit to visually refresh a page. Saves and restores scroll position.
    private func invalidatePage(_ pageIdx: Int) {
        guard let pdfView = session.pdfViewRef,
              let doc = pdfView.document,
              let page = doc.page(at: pageIdx) else {
            NSLog("invalidatePage \(pageIdx): SKIPPED pdfViewRef=\(session.pdfViewRef != nil) doc=\(session.pdfViewRef?.document != nil)")
            return
        }
        NSLog("invalidatePage \(pageIdx): executing, annotations=\(page.annotations.count)")
        let dest = pdfView.currentDestination
        doc.removePage(at: pageIdx)
        doc.insert(page, at: pageIdx)
        if let dest { pdfView.go(to: dest) }
    }

    // MARK: - Private

    private func annotationLayer(for pageIndex: Int) -> StrokeAnnotationLayer? {
        if let existing = annotationLayers[pageIndex] { return existing }
        guard let pdfView = session.pdfViewRef,
              let page = pdfView.document?.page(at: pageIndex) else { return nil }
        let layer = StrokeAnnotationLayer(page: page)
        annotationLayers[pageIndex] = layer
        return layer
    }

}
#endif
