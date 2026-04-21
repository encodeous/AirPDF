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
    let onVCReady: ((DrawingViewController) -> Void)?

    func makeUIViewController(context: Context) -> DrawingViewController {
        let vc = DrawingViewController()
        vc.onStrokeDelta = onStrokeDelta
        vc.loadDocument(doc)
        onVCReady?(vc)
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
    private let toolPicker: PKToolPicker = {
        let tp = PKToolPicker()
        tp.overrideUserInterfaceStyle = .light
        return tp
    }()
    let overlayCoordinator = OverlayCoordinator()
    private var pendingDoc: TabDocument?

    override var canBecomeFirstResponder: Bool { true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(undo(_:)) || action == #selector(redo(_:)) { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func undo(_ sender: Any?) {
        onStrokeDelta?(.wrap(.undo({ var m = Airpdf_V1_Undo(); m.documentID = overlayCoordinator.docId; return m }())))
    }

    @objc func redo(_ sender: Any?) {
        onStrokeDelta?(.wrap(.redo({ var m = Airpdf_V1_Redo(); m.documentID = overlayCoordinator.docId; return m }())))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.overrideUserInterfaceStyle = .light

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

    func applyRemoteStrokeRemove(pageIndex: Int, strokeIds: [String]) {
        overlayCoordinator.applyRemoteStrokeRemove(pageIndex: pageIndex, strokeIds: strokeIds)
    }

    func applyRemoteStrokeBatch(pageIndex: Int, entries: [(id: String, stroke: PKStroke)]) {
        overlayCoordinator.applyRemoteStrokeBatch(pageIndex: pageIndex, entries: entries)
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

    var docId = ""
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

    /// Apply a remote drawing update (Mac undo/redo feedback).
    /// Updates stored drawing data and refreshes the live canvas if visible.
    func applyRemoteDrawingUpdate(pageIndex: Int, drawingData: Data) {
        pageDrawings[pageIndex] = drawingData
        guard let drawing = try? PKDrawing(data: drawingData) else { return }
        // Find the canvas for this page index
        for (page, canvas) in pageToViewMapping {
            guard let doc = page.document, doc.index(for: page) == pageIndex else { continue }
            canvas.delegate = nil  // suppress delta emission during programmatic update
            canvas.drawing = drawing
            differs[pageIndex]?.resetBaseline(drawing)
            canvas.delegate = differs[pageIndex]
            return
        }
        // Canvas not visible — update differ baseline so next display is correct
        differs[pageIndex]?.resetBaseline(drawing)
    }

    /// Remove strokes by ID from the canvas (Mac undo feedback).
    func applyRemoteStrokeRemove(pageIndex: Int, strokeIds: [String]) {
        guard let differ = differs[pageIndex] else { return }
        let updated = differ.removeStrokes(ids: Set(strokeIds))
        guard let data = try? updated.dataRepresentation() else { return }
        pageDrawings[pageIndex] = data
        applyDrawingToCanvas(pageIndex: pageIndex, drawing: updated, differ: differ)
    }

    /// Add strokes to the canvas (Mac redo feedback).
    func applyRemoteStrokeBatch(pageIndex: Int, entries: [(id: String, stroke: PKStroke)]) {
        let differ = differs[pageIndex] ?? {
            let d = StrokeDiffer(pageIndex: pageIndex, documentId: docId, baseline: PKDrawing())
            d.onDelta = { [weak self] env in self?.onStrokeDelta?(env) }
            differs[pageIndex] = d
            return d
        }()
        let updated = differ.addStrokes(entries: entries)
        guard let data = try? updated.dataRepresentation() else { return }
        pageDrawings[pageIndex] = data
        applyDrawingToCanvas(pageIndex: pageIndex, drawing: updated, differ: differ)
    }

    private func applyDrawingToCanvas(pageIndex: Int, drawing: PKDrawing, differ: StrokeDiffer) {
        for (page, canvas) in pageToViewMapping {
            guard let doc = page.document, doc.index(for: page) == pageIndex else { continue }
            canvas.delegate = nil
            canvas.drawing = drawing
            canvas.delegate = differ
            return
        }
    }

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let doc = view.document else { return nil }
        let idx = doc.index(for: page)

        if let existing = pageToViewMapping[page] {
            logger.info("overlayViewFor page \(idx): returning cached canvas")
            return existing
        }

        let canvas = PKCanvasView(frame: .zero)
        canvas.drawingPolicy = .pencilOnly
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
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
        logger.info("overlayViewFor page \(idx): created canvas, delegate=\(canvas.delegate != nil)")
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

    /// Remove strokes by ID (Mac undo feedback). Returns the updated drawing data.
    @discardableResult
    func removeStrokes(ids: Set<String>) -> PKDrawing {
        known.removeAll { ids.contains($0.id) }
        return PKDrawing(strokes: known.map { $0.stroke })
    }

    /// Add strokes from Mac (redo feedback). Returns the updated drawing data.
    @discardableResult
    func addStrokes(entries: [(id: String, stroke: PKStroke)]) -> PKDrawing {
        known.append(contentsOf: entries)
        return PKDrawing(strokes: known.map { $0.stroke })
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let current = canvasView.drawing.strokes
        let knownCount = known.count
        logger.info("drawingDidChange page \(self.pageIndex): current=\(current.count) known=\(knownCount)")

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
        } else if current.count < knownCount {            // Strokes removed (erase / undo)
            var remaining: [(id: String, stroke: PKStroke)] = []
            var removedIds: [String] = []
            var ci = 0
            for (sid, stroke) in known {
                if ci < current.count && strokesMatch(stroke, current[ci]) {
                    remaining.append((sid, current[ci]))
                    ci += 1
                } else {
                    removedIds.append(sid)
                }
            }
            if !removedIds.isEmpty {
                var rm = Airpdf_V1_StrokeRemove()
                rm.documentID = documentId
                rm.pageIndex = UInt32(pageIndex)
                rm.strokeIds = removedIds
                onDelta?(.wrap(.strokeRemove(rm)))
            }
            known = remaining
        } else {
            // Equal count — strokes may have been modified (lasso move/transform)
            var changed = false
            for i in 0..<current.count {
                if !strokesMatch(known[i].stroke, current[i]) { changed = true; break }
            }
            guard changed else { return }
            var rm = Airpdf_V1_StrokeRemove()
            rm.documentID = documentId
            rm.pageIndex = UInt32(pageIndex)
            rm.strokeIds = known.map { $0.id }
            onDelta?(.wrap(.strokeRemove(rm)))
            var batch = Airpdf_V1_StrokeBatch()
            batch.documentID = documentId
            batch.pageIndex = UInt32(pageIndex)
            var newKnown: [(id: String, stroke: PKStroke)] = []
            for stroke in current {
                let sid = UUID().uuidString
                newKnown.append((sid, stroke))
                var entry = Airpdf_V1_StrokeEntry()
                entry.strokeID = sid
                entry.pkStrokeData = (try? PKDrawing(strokes: [stroke]).dataRepresentation()) ?? Data()
                batch.strokes.append(entry)
            }
            onDelta?(.wrap(.strokeBatch(batch)))
            known = newKnown
        }
    }

    private func strokesMatch(_ a: PKStroke, _ b: PKStroke) -> Bool {
        guard a.path.count == b.path.count && a.ink.color == b.ink.color else { return false }
        // Lasso move changes the stroke's transform, not the path points
        if a.transform != b.transform { return false }
        return true
    }
}
#endif
