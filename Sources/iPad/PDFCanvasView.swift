#if os(iOS)
import UIKit
import PDFKit
import PencilKit
import SwiftUI
import os

private let logger = Logger(subsystem: "dev.airpdf.ipad", category: "PDFCanvas")

// MARK: - SwiftUI bridge

/// Displays a PDF with per-page PencilKit canvas overlays using PDFPageOverlayViewProvider.
/// Pencil strokes are diffed and emitted as StrokeBatch/StrokeRemove via onStrokeDelta.
struct PDFCanvasView: UIViewControllerRepresentable {
    let doc: TabDocument
    let onStrokeDelta: (Airpdf_V1_SyncEnvelope) -> Void

    func makeUIViewController(context: Context) -> DrawingViewController {
        let vc = DrawingViewController()
        vc.onStrokeDelta = onStrokeDelta
        vc.loadDocument(doc)
        return vc
    }

    func updateUIViewController(_ vc: DrawingViewController, context: Context) {
        vc.onStrokeDelta = onStrokeDelta
    }
}

// MARK: - Drawing view controller

/// Hosts a PDFView and acts as its PDFPageOverlayViewProvider.
///
/// Following WWDC 2022 session 10089:
/// - overlayViewFor: create or retrieve a PKCanvasView, restore drawing, return it.
///   PDFKit sizes and positions it automatically.
/// - willDisplayOverlayView: install gesture failure relationships if needed.
/// - willEndDisplayingOverlayView: save drawing state, remove from active map, release.
///
/// The tool picker is anchored to the view controller (not to any canvas) so it
/// remains visible regardless of overlay recycling during scroll/zoom.
final class DrawingViewController: UIViewController {
    var onStrokeDelta: ((Airpdf_V1_SyncEnvelope) -> Void)?

    private let pdfView = PDFView()
    private let toolPicker = PKToolPicker()
    private let overlayCoordinator = OverlayCoordinator()
    private var pendingDoc: TabDocument?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()

        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.isInMarkupMode = true
        pdfView.pageOverlayViewProvider = overlayCoordinator
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Tool picker: anchor to this VC so it survives overlay recycling.
        toolPicker.addObserver(self)
        toolPicker.setVisible(true, forFirstResponder: self)

        if let doc = pendingDoc {
            pendingDoc = nil
            applyDocument(doc)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    func loadDocument(_ doc: TabDocument) {
        overlayCoordinator.reset()

        guard isViewLoaded else {
            pendingDoc = doc
            return
        }
        applyDocument(doc)
    }

    private func applyDocument(_ doc: TabDocument) {
        overlayCoordinator.configure(
            docId: doc.id,
            pageDrawings: doc.pageDrawings,
            toolPicker: toolPicker,
            onStrokeDelta: { [weak self] env in self?.onStrokeDelta?(env) }
        )
        pdfView.document = PDFDocument(data: doc.pdfData)
        becomeFirstResponder()
        logger.info("applyDocument: \(doc.id), \(doc.pageCount) pages")
    }
}

// MARK: - PKToolPickerObserver on the VC

extension DrawingViewController: PKToolPickerObserver {
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        // Push selected tool to all currently-visible canvases
        for canvas in overlayCoordinator.activeCanvases {
            canvas.tool = toolPicker.selectedTool
        }
    }
}

// MARK: - Overlay coordinator

/// Manages the lifecycle of per-page PKCanvasView overlays as described in WWDC 2022.
/// Separate from the VC so it can be set as pageOverlayViewProvider (which requires NSObject).
final class OverlayCoordinator: NSObject, PDFPageOverlayViewProvider {

    /// Currently-displayed canvases. Populated in overlayViewFor, removed in willEndDisplaying.
    private var pageToViewMapping: [PDFPage: PKCanvasView] = [:]

    /// Persisted drawing data for every page. Survives overlay teardown.
    private var pageDrawings: [Int: Data] = [:]

    /// Stroke differs keyed by page index. Persist across overlay recycling
    /// because they hold stroke_id → PKStroke mapping.
    private var differs: [Int: StrokeDiffer] = [:]

    private var docId = ""
    private weak var toolPicker: PKToolPicker?
    private var onStrokeDelta: ((Airpdf_V1_SyncEnvelope) -> Void)?

    var activeCanvases: [PKCanvasView] { Array(pageToViewMapping.values) }

    func configure(docId: String, pageDrawings: [Int: Data],
                   toolPicker: PKToolPicker,
                   onStrokeDelta: @escaping (Airpdf_V1_SyncEnvelope) -> Void) {
        self.docId = docId
        self.pageDrawings = pageDrawings
        self.toolPicker = toolPicker
        self.onStrokeDelta = onStrokeDelta
    }

    func reset() {
        pageToViewMapping = [:]
        differs = [:]
        pageDrawings = [:]
    }

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let doc = view.document else { return nil }
        let idx = doc.index(for: page)

        if let existing = pageToViewMapping[page] { return existing }

        let canvas = PKCanvasView(frame: .zero)
        canvas.drawingPolicy = .pencilOnly
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        if let tool = toolPicker?.selectedTool {
            canvas.tool = tool
        }

        if let data = pageDrawings[idx], let drawing = try? PKDrawing(data: data) {
            canvas.drawing = drawing
        }

        let differ: StrokeDiffer
        if let existing = differs[idx] {
            differ = existing
        } else {
            differ = StrokeDiffer(pageIndex: idx, documentId: docId, baseline: canvas.drawing)
            differ.onDelta = { [weak self] env in self?.onStrokeDelta?(env) }
            differs[idx] = differ
        }
        canvas.delegate = differ

        toolPicker?.addObserver(canvas)
        pageToViewMapping[page] = canvas
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView,
              let doc = pdfView.document else { return }
        let idx = doc.index(for: page)

        pageDrawings[idx] = (try? canvas.drawing.dataRepresentation()) ?? Data()
        toolPicker?.removeObserver(canvas)
        pageToViewMapping.removeValue(forKey: page)
    }
}

// MARK: - Stroke differ

/// Tracks per-page stroke identity and emits StrokeBatch / StrokeRemove deltas.
/// Persists across overlay recycling because stroke_id state must survive teardown.
final class StrokeDiffer: NSObject, PKCanvasViewDelegate {
    let pageIndex: Int
    let documentId: String
    var onDelta: ((Airpdf_V1_SyncEnvelope) -> Void)?

    private var known: [(id: String, stroke: PKStroke)] = []

    init(pageIndex: Int, documentId: String, baseline: PKDrawing) {
        self.pageIndex = pageIndex
        self.documentId = documentId
        super.init()
        known = baseline.strokes.map { (UUID().uuidString, $0) }
    }

    func resetBaseline(_ drawing: PKDrawing) {
        known = drawing.strokes.map { (UUID().uuidString, $0) }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let current = canvasView.drawing.strokes
        let knownCount = known.count

        if current.count > knownCount {
            // New strokes appended
            var batch = Airpdf_V1_StrokeBatch()
            batch.documentID = documentId
            batch.pageIndex = UInt32(pageIndex)
            for stroke in current[knownCount...] {
                let sid = UUID().uuidString
                known.append((sid, stroke))
                var entry = Airpdf_V1_StrokeEntry()
                entry.strokeID = sid
                entry.pkStrokeData = (try? PKDrawing(strokes: [stroke]).dataRepresentation()) ?? Data()
                batch.strokes.append(entry)
            }
            onDelta?(.wrap(.strokeBatch(batch)))
        } else if current.count < knownCount {
            // Strokes removed (erase / undo)
            var remaining: [(id: String, stroke: PKStroke)] = []
            var ci = 0
            for (sid, stroke) in known {
                if ci < current.count && strokesMatch(stroke, current[ci]) {
                    remaining.append((sid, current[ci]))
                    ci += 1
                } else {
                    var rm = Airpdf_V1_StrokeRemove()
                    rm.documentID = documentId
                    rm.pageIndex = UInt32(pageIndex)
                    rm.strokeID = sid
                    onDelta?(.wrap(.strokeRemove(rm)))
                }
            }
            known = remaining
        }
    }

    private func strokesMatch(_ a: PKStroke, _ b: PKStroke) -> Bool {
        a.path.count == b.path.count && a.ink.color == b.ink.color
    }
}
#endif
