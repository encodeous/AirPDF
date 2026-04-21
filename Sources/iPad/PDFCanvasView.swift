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
        var items = PKToolPicker().toolItems.filter { !($0 is PKToolPickerEraserItem) }
        let eraser = PKToolPickerEraserItem(type: .vector)
        if let lassoIdx = items.firstIndex(where: { $0 is PKToolPickerLassoItem }) {
            items.insert(eraser, at: lassoIdx)
        } else {
            items.append(eraser)
        }
        let tp = PKToolPicker(toolItems: items)
        tp.overrideUserInterfaceStyle = .light
        return tp
    }()
    let overlayCoordinator = OverlayCoordinator()
    private var pendingDoc: TabDocument?

    override var canBecomeFirstResponder: Bool { true }

    /// Register one undo action on the VC's undoManager so PKToolPicker's built-in
    /// undo/redo buttons stay in sync with the Mac's stroke log.
    func registerUndoAction() {
        undoManager?.registerUndo(withTarget: self) { vc in
            vc.onStrokeDelta?(.wrap(.undo({ var m = Airpdf_V1_Undo(); m.documentID = vc.overlayCoordinator.docId; return m }())))
            vc.undoManager?.registerUndo(withTarget: vc) { vc2 in
                vc2.onStrokeDelta?(.wrap(.redo({ var m = Airpdf_V1_Redo(); m.documentID = vc2.overlayCoordinator.docId; return m }())))
                vc2.registerUndoAction()
            }
        }
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
        undoManager?.removeAllActions()

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
        overlayCoordinator.onNeedsFirstResponder = { [weak self] in self?.becomeFirstResponder() }
        overlayCoordinator.onStrokeCommitted = { [weak self] in self?.registerUndoAction() }
        pdfView.document = PDFDocument(data: doc.pdfData)
        becomeFirstResponder()
        logger.info("applyDocument: \(doc.id), \(doc.pageCount) pages")
    }
}

// MARK: - PKToolPickerObserver on the VC

extension DrawingViewController: PKToolPickerObserver {
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        let needsEditMode = toolPicker.selectedToolItem is PKToolPickerEraserItem
            || toolPicker.selectedToolItem is PKToolPickerLassoItem
        if needsEditMode && !overlayCoordinator.isEditMode {
            overlayCoordinator.enterEditMode()
        } else if !needsEditMode && overlayCoordinator.isEditMode {
            overlayCoordinator.exitEditMode()
        }
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

    /// Per-page annotation layers managing 8× stamp annotations on the PDFPage.
    private var annotationLayers: [Int: StrokeAnnotationLayer] = [:]

    /// Strokes that have been committed to annotations, keyed by page index.
    /// This is the source of truth for what's in annotations (needed for eraser mode restore).
    private var committedStrokes: [Int: [(id: String, stroke: PKStroke)]] = [:]

    /// True when the eraser tool is active — strokes live on the canvas, not as annotations.
    private(set) var isEditMode = false
    /// Pending eraser setup per page after overlay recreation from page invalidation.
    private var pendingEditSetup: [Int: [(id: String, stroke: PKStroke)]] = [:]

    var docId = ""
    private weak var toolPicker: PKToolPicker?
    private weak var pdfViewRef: PDFView?
    private var onStrokeDelta: ((Airpdf_V1_SyncEnvelope) -> Void)?
    /// Called after page re-insert to reclaim first responder on the VC.
    var onNeedsFirstResponder: (() -> Void)?
    /// Called when a stroke is committed to annotations — VC registers an undo action.
    var onStrokeCommitted: (() -> Void)?

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
        for layer in annotationLayers.values { layer.removeAll() }
        pageToViewMapping = [:]
        differs = [:]
        pageDrawings = [:]
        annotationLayers = [:]
        committedStrokes = [:]
        pendingEditSetup = [:]
        isEditMode = false
    }

    /// Look up the PDFPage for a given page index from any active canvas.
    private func pdfPage(for pageIndex: Int) -> PDFPage? {
        for (page, _) in pageToViewMapping {
            guard let doc = page.document, doc.index(for: page) == pageIndex else { continue }
            return page
        }
        return nil
    }

    /// Get or create the annotation layer for a page index.
    private func annotationLayer(for pageIndex: Int) -> StrokeAnnotationLayer? {
        if let existing = annotationLayers[pageIndex] { return existing }
        guard let page = pdfPage(for: pageIndex) else { return nil }
        let layer = StrokeAnnotationLayer(page: page)
        annotationLayers[pageIndex] = layer
        return layer
    }

    /// Add finalized strokes as annotations and clear the canvas overlay.
    func commitStrokesToAnnotations(pageIndex: Int, newStrokes: [(id: String, stroke: PKStroke)]) {
        guard !isEditMode, let layer = annotationLayer(for: pageIndex) else { return }
        let newIds = newStrokes.map { $0.id }
        logger.info("commitStrokesToAnnotations page \(pageIndex): newIds=\(newIds)")
        for (id, stroke) in newStrokes {
            layer.addStroke(id: id, stroke: stroke)
        }
        // Update pageDrawings with the full drawing (existing + new strokes)
        let allStrokes = (committedStrokes[pageIndex] ?? []) + newStrokes
        committedStrokes[pageIndex] = allStrokes
        let drawing = PKDrawing(strokes: allStrokes.map { $0.stroke })
        pageDrawings[pageIndex] = (try? drawing.dataRepresentation()) ?? Data()
        // Clear the canvas and differ — strokes now live in annotations, not on the canvas.
        differs[pageIndex]?.clearKnown()
        clearCanvas(pageIndex: pageIndex)
        onStrokeCommitted?()
    }

    /// Remove stroke annotations by ID.
    func removeStrokeAnnotations(pageIndex: Int, ids: Set<String>) {
        committedStrokes[pageIndex]?.removeAll { ids.contains($0.id) }
        if !isEditMode {
            // Only touch annotations outside eraser mode.
            // During eraser mode, annotations are already removed; canvas is the display layer.
            annotationLayers[pageIndex]?.removeStrokes(ids: ids)
        }
    }

    // MARK: - Eraser mode

    /// Enter eraser mode: remove annotations, force page re-render, defer canvas setup to overlayViewFor.
    func enterEditMode() {
        guard !isEditMode else { return }
        isEditMode = true
        // Collect pages to invalidate
        var pagesToInvalidate: [(PDFPage, Int)] = []
        for (page, _) in pageToViewMapping {
            guard let doc = page.document else { continue }
            let idx = doc.index(for: page)
            guard let strokes = committedStrokes[idx], !strokes.isEmpty else { continue }
            annotationLayers[idx]?.removeAll()
            pendingEditSetup[idx] = strokes
            pagesToInvalidate.append((page, idx))
        }
        // Force page re-render — tears down overlays, overlayViewFor will pick up pendingEditSetup
        // Save scroll position via the underlying UIScrollView for pixel-exact restore.
        let scrollView = pdfViewRef?.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView
        let savedOffset = scrollView?.contentOffset
        for (page, _) in pagesToInvalidate {
            guard let doc = page.document else { continue }
            let pageIndex = doc.index(for: page)
            doc.removePage(at: pageIndex)
            doc.insert(page, at: pageIndex)
        }
        if let savedOffset { scrollView?.contentOffset = savedOffset }
        onNeedsFirstResponder?()
    }

    /// Exit edit mode: clear canvas, re-add surviving strokes as annotations.
    func exitEditMode() {
        guard isEditMode else { return }
        isEditMode = false
        for (page, canvas) in pageToViewMapping {
            guard let doc = page.document else { continue }
            let idx = doc.index(for: page)
            guard let differ = differs[idx] else { continue }
            // Update committedStrokes with surviving strokes from the differ
            let surviving = differ.knownStrokes
            committedStrokes[idx] = surviving
            // Update pageDrawings
            let drawing = PKDrawing(strokes: surviving.map { $0.stroke })
            pageDrawings[idx] = (try? drawing.dataRepresentation()) ?? Data()
            // Re-add surviving strokes as annotations
            if let layer = annotationLayer(for: idx) {
                for (id, stroke) in surviving {
                    layer.addStroke(id: id, stroke: stroke)
                }
            }
            // Clear canvas and differ
            differ.isEditMode = false
            differ.clearKnown()
            canvas.delegate = nil
            canvas.drawing = PKDrawing()
            canvas.delegate = differ
        }
    }

    /// Clear the canvas drawing without emitting a delta.
    private func clearCanvas(pageIndex: Int) {
        for (page, canvas) in pageToViewMapping {
            guard let doc = page.document, doc.index(for: page) == pageIndex else { continue }
            let differ = differs[pageIndex]
            canvas.delegate = nil
            canvas.drawing = PKDrawing()
            canvas.delegate = differ
            return
        }
    }

    /// Apply a remote drawing update (Mac undo/redo feedback).
    /// Rebuilds annotations from the new drawing. Uses page re-insert to clear stale visuals.
    func applyRemoteDrawingUpdate(pageIndex: Int, drawingData: Data) {
        pageDrawings[pageIndex] = drawingData
        guard let drawing = try? PKDrawing(data: drawingData) else { return }
        let strokes: [(id: String, stroke: PKStroke)] = drawing.strokes.map { (UUID().uuidString, $0) }
        committedStrokes[pageIndex] = strokes
        differs[pageIndex]?.clearKnown()
        // Nuke old annotation layer
        annotationLayers[pageIndex]?.removeAll()
        annotationLayers.removeValue(forKey: pageIndex)
        // Create fresh layer with new strokes (before page re-insert so overlayViewFor sees it)
        guard let page = pdfPage(for: pageIndex) else { return }
        let layer = StrokeAnnotationLayer(page: page)
        annotationLayers[pageIndex] = layer
        for (id, stroke) in strokes {
            layer.addStroke(id: id, stroke: stroke)
        }
        // Page re-insert to clear stale annotation visuals
        guard let doc = page.document else { return }
        let scrollView = pdfViewRef?.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView
        let savedOffset = scrollView?.contentOffset
        let idx = doc.index(for: page)
        doc.removePage(at: idx)
        doc.insert(page, at: idx)
        if let savedOffset { scrollView?.contentOffset = savedOffset }
        onNeedsFirstResponder?()
    }

    /// Remove strokes by ID (Mac undo feedback). Updates annotations.
    func applyRemoteStrokeRemove(pageIndex: Int, strokeIds: [String]) {
        guard differs[pageIndex] != nil else { return }
        removeStrokeAnnotations(pageIndex: pageIndex, ids: Set(strokeIds))
        // Update pageDrawings from committedStrokes
        let strokes = committedStrokes[pageIndex] ?? []
        let drawing = PKDrawing(strokes: strokes.map { $0.stroke })
        pageDrawings[pageIndex] = (try? drawing.dataRepresentation()) ?? Data()
    }

    /// Add strokes (Mac redo feedback). Updates annotations.
    func applyRemoteStrokeBatch(pageIndex: Int, entries: [(id: String, stroke: PKStroke)]) {
        // Ensure differ exists (but keep it empty — strokes go to annotations)
        if differs[pageIndex] == nil {
            let d = StrokeDiffer(pageIndex: pageIndex, documentId: docId, baseline: PKDrawing())
            d.onDelta = { [weak self] env in self?.onStrokeDelta?(env) }
            d.onStrokesAdded = { [weak self] pi, ns in self?.commitStrokesToAnnotations(pageIndex: pi, newStrokes: ns) }
            d.onStrokesRemoved = { [weak self] pi, ids in self?.removeStrokeAnnotations(pageIndex: pi, ids: ids) }
            differs[pageIndex] = d
        }
        // Add to committedStrokes and annotations
        var existing = committedStrokes[pageIndex] ?? []
        existing.append(contentsOf: entries)
        committedStrokes[pageIndex] = existing
        let drawing = PKDrawing(strokes: existing.map { $0.stroke })
        pageDrawings[pageIndex] = (try? drawing.dataRepresentation()) ?? Data()
        if let layer = annotationLayer(for: pageIndex) {
            for (id, stroke) in entries {
                layer.addStroke(id: id, stroke: stroke)
            }
        }
    }

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let doc = view.document else { return nil }
        let idx = doc.index(for: page)
        pdfViewRef = view

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

        // Restore drawing data into the differ baseline (for stroke ID tracking)
        var baseline = PKDrawing()
        if let data = pageDrawings[idx], let drawing = try? PKDrawing(data: data) {
            baseline = drawing
        }

        let differ: StrokeDiffer
        if let existing = differs[idx] {
            differ = existing
        } else {
            differ = StrokeDiffer(pageIndex: idx, documentId: docId, baseline: baseline)
            differ.onDelta = { [weak self] env in self?.onStrokeDelta?(env) }
            differs[idx] = differ
        }
        differ.onStrokesAdded = { [weak self] pageIndex, newStrokes in
            self?.commitStrokesToAnnotations(pageIndex: pageIndex, newStrokes: newStrokes)
        }
        differ.onStrokesRemoved = { [weak self] pageIndex, removedIds in
            self?.removeStrokeAnnotations(pageIndex: pageIndex, ids: removedIds)
        }
        canvas.delegate = differ

        // Create annotation layer and render existing strokes as annotations.
        // Canvas stays empty — annotations are the display layer.
        // Skip if entering eraser mode — annotations were just cleared.
        if annotationLayers[idx] == nil && pendingEditSetup[idx] == nil {
            let layer = StrokeAnnotationLayer(page: page)
            annotationLayers[idx] = layer
            let strokes = differ.knownStrokes
            committedStrokes[idx] = strokes
            for (id, stroke) in strokes {
                layer.addStroke(id: id, stroke: stroke)
            }
            // Differ known is now committed — clear it so canvas state matches (empty)
            differ.clearKnown()
        }

        // If entering edit mode, restore strokes to canvas for PencilKit eraser/lasso
        if let editStrokes = pendingEditSetup.removeValue(forKey: idx) {
            canvas.delegate = nil
            let drawing = PKDrawing(strokes: editStrokes.map { $0.stroke })
            canvas.drawing = drawing
            let canvasStrokes = canvas.drawing.strokes
            let paired: [(id: String, stroke: PKStroke)]
            if canvasStrokes.count == editStrokes.count {
                paired = zip(editStrokes, canvasStrokes).map { ($0.0.id, $0.1) }
            } else {
                paired = editStrokes
            }
            differ.restoreKnown(paired)
            differ.isEditMode = true
            canvas.delegate = differ
        }

        toolPicker?.addObserver(canvas)
        pageToViewMapping[page] = canvas
        logger.info("overlayViewFor page \(idx): created canvas, \(differ.knownStrokes.count) strokes as annotations")
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        // Canvas is empty (strokes live in annotations), nothing to persist.
        // Annotation layers and differs survive overlay recycling.
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
    /// Called after new strokes are added to `known` so the coordinator can commit them as annotations.
    var onStrokesAdded: ((_ pageIndex: Int, _ newStrokes: [(id: String, stroke: PKStroke)]) -> Void)?
    /// Called after strokes are removed from `known` so the coordinator can remove annotations.
    var onStrokesRemoved: ((_ pageIndex: Int, _ removedIds: Set<String>) -> Void)?
    /// When true, use fingerprint-based removal (strokesMatch is unreliable on restored strokes).
    var isEditMode = false
    /// Fingerprint → stroke ID map built at edit mode entry from canvas-returned strokes.
    private var editFingerprints: [Data: String] = [:]

    private var known: [(id: String, stroke: PKStroke)] = []

    /// Read-only access to the current known strokes (for annotation layer rebuilds).
    var knownStrokes: [(id: String, stroke: PKStroke)] { known }

    init(pageIndex: Int, documentId: String, baseline: PKDrawing) {
        self.pageIndex = pageIndex
        self.documentId = documentId
        super.init()
        known = baseline.strokes.map { (UUID().uuidString, $0) }
    }

    func resetBaseline(_ drawing: PKDrawing) {
        known = drawing.strokes.map { (UUID().uuidString, $0) }
    }

    /// Clear the known list (canvas was emptied, strokes moved to annotations).
    func clearKnown() {
        known = []
    }

    /// Restore known strokes with their original IDs and build fingerprint map for edit mode matching.
    func restoreKnown(_ strokes: [(id: String, stroke: PKStroke)]) {
        known = strokes
        editFingerprints.removeAll()
        for (sid, stroke) in strokes {
            let fp = (try? PKDrawing(strokes: [stroke]).dataRepresentation()) ?? Data()
            editFingerprints[fp] = sid
        }
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
            var newStrokes: [(id: String, stroke: PKStroke)] = []
            for stroke in current[knownCount...] {
                let sid = UUID().uuidString
                known.append((sid, stroke))
                newStrokes.append((sid, stroke))
                var entry = Airpdf_V1_StrokeEntry()
                entry.strokeID = sid
                entry.pkStrokeData = (try? PKDrawing(strokes: [stroke]).dataRepresentation()) ?? Data()
                batch.strokes.append(entry)
            }
            onDelta?(.wrap(.strokeBatch(batch)))
            onStrokesAdded?(pageIndex, newStrokes)
        } else if current.count < knownCount {            // Strokes removed (erase / undo)
            var remaining: [(id: String, stroke: PKStroke)] = []
            var removedIds: [String] = []
            if isEditMode {
                // strokesMatch is unreliable on restored strokes. Use randomSeed as unique fingerprint.
                var knownBySeed: [UInt32: String] = [:]
                for (sid, stroke) in known {
                    knownBySeed[stroke.randomSeed] = sid
                }
                for stroke in current {
                    if let sid = knownBySeed[stroke.randomSeed] {
                        remaining.append((sid, stroke))
                    }
                }
                let matchedIds = Set(remaining.map { $0.id })
                for (sid, _) in known where !matchedIds.contains(sid) {
                    removedIds.append(sid)
                }
            } else {
                var ci = 0
                for (sid, stroke) in known {
                    if ci < current.count && strokesMatch(stroke, current[ci]) {
                        remaining.append((sid, current[ci]))
                        ci += 1
                    } else {
                        removedIds.append(sid)
                    }
                }
            }
            known = remaining
            if !removedIds.isEmpty {
                var rm = Airpdf_V1_StrokeRemove()
                rm.documentID = documentId
                rm.pageIndex = UInt32(pageIndex)
                rm.strokeIds = removedIds
                onDelta?(.wrap(.strokeRemove(rm)))
                onStrokesRemoved?(pageIndex, Set(removedIds))
            }
        } else {
            // Equal count — strokes may have been modified (lasso move/transform)
            var changed = false
            for i in 0..<current.count {
                if !strokesMatch(known[i].stroke, current[i]) { changed = true; break }
            }
            guard changed else { return }
            let oldIds = Set(known.map { $0.id })
            var rm = Airpdf_V1_StrokeRemove()
            rm.documentID = documentId
            rm.pageIndex = UInt32(pageIndex)
            rm.strokeIds = Array(oldIds)
            onDelta?(.wrap(.strokeRemove(rm)))
            onStrokesRemoved?(pageIndex, oldIds)
            var batch = Airpdf_V1_StrokeBatch()
            batch.documentID = documentId
            batch.pageIndex = UInt32(pageIndex)
            var newKnown: [(id: String, stroke: PKStroke)] = []
            var newStrokes: [(id: String, stroke: PKStroke)] = []
            for stroke in current {
                let sid = UUID().uuidString
                newKnown.append((sid, stroke))
                newStrokes.append((sid, stroke))
                var entry = Airpdf_V1_StrokeEntry()
                entry.strokeID = sid
                entry.pkStrokeData = (try? PKDrawing(strokes: [stroke]).dataRepresentation()) ?? Data()
                batch.strokes.append(entry)
            }
            onDelta?(.wrap(.strokeBatch(batch)))
            known = newKnown
            onStrokesAdded?(pageIndex, newStrokes)
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
