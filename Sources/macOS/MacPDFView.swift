#if os(macOS)
import SwiftUI
import PDFKit
import PencilKit

struct MacPDFView: NSViewRepresentable {
    let document: PDFDocument
    let session: DocumentSession

    func makeCoordinator() -> MacOverlayCoordinator {
        MacOverlayCoordinator(session: session)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.pageOverlayViewProvider = context.coordinator
        view.document = document
        session.pdfViewRef = view
        session.overlayCoordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
            session.pdfViewRef = nsView
        }
        // Refresh overlays when drawings change
        if session.needsDisplayUpdate {
            session.needsDisplayUpdate = false
            context.coordinator.refreshOverlays()
        }
    }
}

/// Provides per-page overlay NSViews that render PKDrawing as vector on the Mac.
final class MacOverlayCoordinator: NSObject, PDFPageOverlayViewProvider {
    let session: DocumentSession
    private var overlays: [PDFPage: DrawingOverlayView] = [:]

    init(session: DocumentSession) {
        self.session = session
    }

    func refreshOverlays() {
        for (page, overlay) in overlays {
            guard let doc = page.document else { continue }
            let idx = doc.index(for: page)
            if let data = session.pageDrawings[idx], let drawing = try? PKDrawing(data: data) {
                overlay.drawing = drawing
            } else {
                overlay.drawing = PKDrawing()
            }
            overlay.needsDisplay = true
        }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        if let existing = overlays[page] { return existing }

        guard let doc = view.document else { return nil }
        let idx = doc.index(for: page)

        let overlay = DrawingOverlayView()
        overlay.appearance = NSAppearance(named: .aqua)
        if let data = session.pageDrawings[idx], let drawing = try? PKDrawing(data: data) {
            overlay.drawing = drawing
        }
        overlays[page] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        overlays.removeValue(forKey: page)
    }
}

/// A simple NSView that renders a PKDrawing using its vector image representation.
final class DrawingOverlayView: NSView {
    var drawing = PKDrawing()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard !drawing.strokes.isEmpty else { return }
        // Render at high scale for crispness
        let scale = window?.backingScaleFactor ?? 2.0
        let image = drawing.image(from: drawing.bounds, scale: scale)
        image.draw(in: drawing.bounds)
    }
}
#endif
