#if os(iOS)
import UIKit
import PDFKit
import PencilKit
import SwiftUI
import os

private let logger = Logger(subsystem: "dev.airpdf.ipad", category: "PDFCanvas")

// MARK: - SwiftUI bridge

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

    func registerUndoAction() {
        undoManager?.registerUndo(withTarget: self) { vc in
            vc.onStrokeDelta?(.wrap(.undo({ var m = Airpdf_V1_Undo(); m.documentID = vc.overlayCoordinator.docId; return m }())))
            vc.undoManager?.registerUndo(withTarget: vc) { vc2 in
                vc2.onStrokeDelta?(.wrap(.redo({ var m = Airpdf_V1_Redo(); m.documentID = vc2.overlayCoordinator.docId; return m }())))
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
        toolPicker.addObserver(self)
        toolPicker.setVisible(true, forFirstResponder: self)
        if let doc = pendingDoc { pendingDoc = nil; applyDocument(doc) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    func loadDocument(_ doc: TabDocument) {
        overlayCoordinator.reset()
        undoManager?.removeAllActions()
        guard isViewLoaded else { pendingDoc = doc; return }
        applyDocument(doc)
    }

    func applyRemoteStrokeRemove(pageIndex: Int, strokeIds: [String]) {
        overlayCoordinator.applyRemoteStrokeRemove(pageIndex: pageIndex, strokeIds: strokeIds)
    }

    func applyRemoteStrokeBatch(pageIndex: Int, entries: [(id: UUID, stroke: PKStroke)]) {
        overlayCoordinator.applyRemoteStrokeBatch(pageIndex: pageIndex, entries: entries)
    }

    func applyRemoteDrawingUpdate(pageIndex: Int, entries: [(id: UUID, stroke: PKStroke)]) {
        overlayCoordinator.applyRemoteDrawingUpdate(pageIndex: pageIndex, entries: entries)
    }

    private func applyDocument(_ doc: TabDocument) {
        overlayCoordinator.configure(
            docId: doc.id, pageStrokes: doc.pageStrokes, toolPicker: toolPicker,
            onStrokeDelta: { [weak self] env in self?.onStrokeDelta?(env) }
        )
        overlayCoordinator.onNeedsFirstResponder = { [weak self] in self?.becomeFirstResponder() }
        overlayCoordinator.onStrokeCommitted = { [weak self] in self?.registerUndoAction() }
        pdfView.document = PDFDocument(data: doc.pdfData)
        becomeFirstResponder()
        logger.info("applyDocument: \(doc.id), \(doc.pageCount) pages")
    }
}

// MARK: - PKToolPickerObserver

extension DrawingViewController: PKToolPickerObserver {
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        let needsEditMode = toolPicker.selectedToolItem is PKToolPickerEraserItem
            || toolPicker.selectedToolItem is PKToolPickerLassoItem
        if needsEditMode && !overlayCoordinator.isEditMode { overlayCoordinator.enterEditMode() }
        else if !needsEditMode && overlayCoordinator.isEditMode { overlayCoordinator.exitEditMode() }
        for canvas in overlayCoordinator.activeCanvases { canvas.tool = toolPicker.selectedTool }
    }
}

// MARK: - Overlay coordinator

final class OverlayCoordinator: NSObject, PDFPageOverlayViewProvider {

    private var pageToViewMapping: [PDFPage: PKCanvasView] = [:]
    /// Canonical stroke list per page — source of truth for annotations.
    private var pageStrokes: [Int: [(id: UUID, stroke: PKStroke)]] = [:]
    private var differs: [Int: StrokeDiffer] = [:]
    private var annotationLayers: [Int: StrokeAnnotationLayer] = [:]
    /// Strokes committed to annotations (authoritative for edit mode restore).
    private var committedStrokes: [Int: [(id: UUID, stroke: PKStroke)]] = [:]
    private(set) var isEditMode = false
    private var pendingEditSetup: [Int: [(id: UUID, stroke: PKStroke)]] = [:]

    var docId = ""
    private weak var toolPicker: PKToolPicker?
    private weak var pdfViewRef: PDFView?
    private var onStrokeDelta: ((Airpdf_V1_SyncEnvelope) -> Void)?
    var onNeedsFirstResponder: (() -> Void)?
    var onStrokeCommitted: (() -> Void)?
    var activeCanvases: [PKCanvasView] { Array(pageToViewMapping.values) }

    func configure(docId: String, pageStrokes: [Int: [(id: UUID, stroke: PKStroke)]],
                   toolPicker: PKToolPicker, onStrokeDelta: @escaping (Airpdf_V1_SyncEnvelope) -> Void) {
        self.docId = docId
        self.pageStrokes = pageStrokes
        self.toolPicker = toolPicker
        self.onStrokeDelta = onStrokeDelta
    }

    func reset() {
        for layer in annotationLayers.values { layer.removeAll() }
        pageToViewMapping = [:]
        differs = [:]
        pageStrokes = [:]
        annotationLayers = [:]
        committedStrokes = [:]
        pendingEditSetup = [:]
        isEditMode = false
    }

    private func pdfPage(for pageIndex: Int) -> PDFPage? {
        pageToViewMapping.keys.first { page in
            page.document.map { $0.index(for: page) == pageIndex } ?? false
        }
    }

    private func annotationLayer(for pageIndex: Int) -> StrokeAnnotationLayer? {
        if let existing = annotationLayers[pageIndex] { return existing }
        guard let page = pdfPage(for: pageIndex) else { return nil }
        let layer = StrokeAnnotationLayer(page: page)
        annotationLayers[pageIndex] = layer
        return layer
    }

    func commitStrokesToAnnotations(pageIndex: Int, newStrokes: [(id: UUID, stroke: PKStroke)]) {
        guard !isEditMode, let layer = annotationLayer(for: pageIndex) else { return }
        logger.info("commitStrokesToAnnotations page \(pageIndex): \(newStrokes.count) strokes")
        for (id, stroke) in newStrokes { layer.addStroke(id: id.uuidString, stroke: stroke) }
        let all = (committedStrokes[pageIndex] ?? []) + newStrokes
        committedStrokes[pageIndex] = all
        pageStrokes[pageIndex] = all
        differs[pageIndex]?.clearKnown()
        clearCanvas(pageIndex: pageIndex)
        onStrokeCommitted?()
    }

    func removeStrokeAnnotations(pageIndex: Int, ids: Set<String>) {
        committedStrokes[pageIndex]?.removeAll { ids.contains($0.id.uuidString) }
        pageStrokes[pageIndex] = committedStrokes[pageIndex] ?? []
        if !isEditMode { annotationLayers[pageIndex]?.removeStrokes(ids: ids) }
    }

    // MARK: - Edit mode

    func enterEditMode() {
        guard !isEditMode else { return }
        isEditMode = true
        var pagesToInvalidate: [(PDFPage, Int)] = []
        for (page, _) in pageToViewMapping {
            guard let doc = page.document else { continue }
            let idx = doc.index(for: page)
            guard let strokes = committedStrokes[idx], !strokes.isEmpty else { continue }
            annotationLayers[idx]?.removeAll()
            pendingEditSetup[idx] = strokes
            pagesToInvalidate.append((page, idx))
        }
        let scrollView = pdfViewRef?.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView
        let savedOffset = scrollView?.contentOffset
        for (page, _) in pagesToInvalidate {
            guard let doc = page.document else { continue }
            let idx = doc.index(for: page)
            doc.removePage(at: idx); doc.insert(page, at: idx)
        }
        if let savedOffset { scrollView?.contentOffset = savedOffset }
        onNeedsFirstResponder?()
    }

    func exitEditMode() {
        guard isEditMode else { return }
        isEditMode = false
        for (page, canvas) in pageToViewMapping {
            guard let doc = page.document else { continue }
            let idx = doc.index(for: page)
            guard let differ = differs[idx] else { continue }
            let surviving = differ.knownStrokes
            committedStrokes[idx] = surviving
            pageStrokes[idx] = surviving
            if let layer = annotationLayer(for: idx) {
                for (id, stroke) in surviving { layer.addStroke(id: id.uuidString, stroke: stroke) }
            }
            differ.isEditMode = false
            differ.clearKnown()
            canvas.delegate = nil; canvas.drawing = PKDrawing(); canvas.delegate = differ
        }
    }

    private func clearCanvas(pageIndex: Int) {
        for (page, canvas) in pageToViewMapping {
            guard let doc = page.document, doc.index(for: page) == pageIndex else { continue }
            canvas.delegate = nil; canvas.drawing = PKDrawing(); canvas.delegate = differs[pageIndex]
            return
        }
    }

    // MARK: - Remote updates

    func applyRemoteDrawingUpdate(pageIndex: Int, entries: [(id: UUID, stroke: PKStroke)]) {
        committedStrokes[pageIndex] = entries
        pageStrokes[pageIndex] = entries
        differs[pageIndex]?.clearKnown()
        annotationLayers[pageIndex]?.removeAll()
        annotationLayers.removeValue(forKey: pageIndex)
        guard let page = pdfPage(for: pageIndex) else { return }
        let layer = StrokeAnnotationLayer(page: page)
        annotationLayers[pageIndex] = layer
        for (id, stroke) in entries { layer.addStroke(id: id.uuidString, stroke: stroke) }
        guard let doc = page.document else { return }
        let scrollView = pdfViewRef?.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView
        let savedOffset = scrollView?.contentOffset
        let idx = doc.index(for: page)
        doc.removePage(at: idx); doc.insert(page, at: idx)
        if let savedOffset { scrollView?.contentOffset = savedOffset }
        onNeedsFirstResponder?()
    }

    func applyRemoteStrokeRemove(pageIndex: Int, strokeIds: [String]) {
        guard differs[pageIndex] != nil else { return }
        removeStrokeAnnotations(pageIndex: pageIndex, ids: Set(strokeIds))
    }

    func applyRemoteStrokeBatch(pageIndex: Int, entries: [(id: UUID, stroke: PKStroke)]) {
        if differs[pageIndex] == nil {
            let d = StrokeDiffer(pageIndex: pageIndex, documentId: docId, baseline: [])
            d.onDelta = { [weak self] env in self?.onStrokeDelta?(env) }
            d.onStrokesAdded = { [weak self] pi, ns in self?.commitStrokesToAnnotations(pageIndex: pi, newStrokes: ns) }
            d.onStrokesRemoved = { [weak self] pi, ids in self?.removeStrokeAnnotations(pageIndex: pi, ids: ids) }
            differs[pageIndex] = d
        }
        var existing = committedStrokes[pageIndex] ?? []
        existing.append(contentsOf: entries)
        committedStrokes[pageIndex] = existing
        pageStrokes[pageIndex] = existing
        if let layer = annotationLayer(for: pageIndex) {
            for (id, stroke) in entries { layer.addStroke(id: id.uuidString, stroke: stroke) }
        }
    }

    // MARK: - PDFPageOverlayViewProvider

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
        if let tool = toolPicker?.selectedTool { canvas.tool = tool }

        let baseline = pageStrokes[idx] ?? []
        let differ: StrokeDiffer
        if let existing = differs[idx] {
            differ = existing
        } else {
            differ = StrokeDiffer(pageIndex: idx, documentId: docId, baseline: baseline)
            differ.onDelta = { [weak self] env in self?.onStrokeDelta?(env) }
            differs[idx] = differ
        }
        differ.onStrokesAdded = { [weak self] pi, ns in self?.commitStrokesToAnnotations(pageIndex: pi, newStrokes: ns) }
        differ.onStrokesRemoved = { [weak self] pi, ids in self?.removeStrokeAnnotations(pageIndex: pi, ids: ids) }
        // Delegate assigned after setup to prevent spurious delta from PDFKit firing
        // canvasViewDrawingDidChange on canvas insertion while known != canvas stroke count.

        if annotationLayers[idx] == nil && pendingEditSetup[idx] == nil {
            let layer = StrokeAnnotationLayer(page: page)
            annotationLayers[idx] = layer
            let strokes = differ.knownStrokes
            committedStrokes[idx] = strokes
            // If eraser/lasso already active on load, go straight to edit mode
            let currentToolNeedsEdit = toolPicker.map {
                $0.selectedToolItem is PKToolPickerEraserItem || $0.selectedToolItem is PKToolPickerLassoItem
            } ?? false
            if currentToolNeedsEdit && !strokes.isEmpty {
                isEditMode = true
                pendingEditSetup[idx] = strokes
                // Don't add annotations — edit mode uses canvas directly
            } else {
                for (id, stroke) in strokes { layer.addStroke(id: id.uuidString, stroke: stroke) }
                differ.clearKnown()
            }
        } else if pendingEditSetup[idx] == nil {
            differ.clearKnown()
        }

        if let editStrokes = pendingEditSetup.removeValue(forKey: idx) {
            canvas.drawing = PKDrawing(strokes: editStrokes.map { $0.stroke })
            let canvasStrokes = canvas.drawing.strokes
            let paired: [(id: UUID, stroke: PKStroke)]
            if canvasStrokes.count == editStrokes.count {
                paired = zip(editStrokes, canvasStrokes).map { ($0.0.id, $0.1) }
            } else {
                paired = editStrokes
            }
            differ.restoreKnown(paired)
            differ.isEditMode = true
        }

        canvas.delegate = differ

        toolPicker?.addObserver(canvas)
        pageToViewMapping[page] = canvas
        logger.info("overlayViewFor page \(idx): created canvas, \(differ.knownStrokes.count) strokes as annotations")
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {}

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        toolPicker?.removeObserver(canvas)
        pageToViewMapping.removeValue(forKey: page)
    }
}

// MARK: - Stroke differ

final class StrokeDiffer: NSObject, PKCanvasViewDelegate {
    let pageIndex: Int
    let documentId: String
    var onDelta: ((Airpdf_V1_SyncEnvelope) -> Void)?
    var onStrokesAdded: ((_ pageIndex: Int, _ newStrokes: [(id: UUID, stroke: PKStroke)]) -> Void)?
    var onStrokesRemoved: ((_ pageIndex: Int, _ removedIds: Set<String>) -> Void)?
    var isEditMode = false

    private var known: [(id: UUID, stroke: PKStroke)] = []
    var knownStrokes: [(id: UUID, stroke: PKStroke)] { known }

    init(pageIndex: Int, documentId: String, baseline: [(id: UUID, stroke: PKStroke)]) {
        self.pageIndex = pageIndex
        self.documentId = documentId
        super.init()
        known = baseline
    }

    func clearKnown() { known = [] }

    func restoreKnown(_ strokes: [(id: UUID, stroke: PKStroke)]) {
        known = strokes
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let current = canvasView.drawing.strokes
        let knownCount = known.count
        logger.info("drawingDidChange page \(self.pageIndex): current=\(current.count) known=\(knownCount)")

        if current.count > knownCount {
            var batch = Airpdf_V1_StrokeBatch()
            batch.documentID = documentId; batch.pageIndex = UInt32(pageIndex)
            var newStrokes: [(id: UUID, stroke: PKStroke)] = []
            for stroke in current[knownCount...] {
                let uuid = UUID()
                known.append((uuid, stroke))
                newStrokes.append((uuid, stroke))
                var entry = Airpdf_V1_StrokeEntry()
                entry.strokeID = uuid.uuidString
                entry.pkStrokeData = (try? PKDrawing(strokes: [stroke]).dataRepresentation()) ?? Data()
                batch.strokes.append(entry)
            }
            onDelta?(.wrap(.strokeBatch(batch)))
            onStrokesAdded?(pageIndex, newStrokes)

        } else if current.count < knownCount {
            var remaining: [(id: UUID, stroke: PKStroke)] = []
            var removedIds: [String] = []
            if isEditMode {
                var knownBySeed: [UInt32: UUID] = [:]
                for (id, stroke) in known { knownBySeed[stroke.randomSeed] = id }
                for stroke in current {
                    if let id = knownBySeed[stroke.randomSeed] { remaining.append((id, stroke)) }
                }
                let matchedIds = Set(remaining.map { $0.id })
                for (id, _) in known where !matchedIds.contains(id) { removedIds.append(id.uuidString) }
            } else {
                var ci = 0
                for (id, stroke) in known {
                    if ci < current.count && strokesMatch(stroke, current[ci]) {
                        remaining.append((id, current[ci])); ci += 1
                    } else {
                        removedIds.append(id.uuidString)
                    }
                }
            }
            known = remaining
            if !removedIds.isEmpty {
                var rm = Airpdf_V1_StrokeRemove()
                rm.documentID = documentId; rm.pageIndex = UInt32(pageIndex); rm.strokeIds = removedIds
                onDelta?(.wrap(.strokeRemove(rm)))
                onStrokesRemoved?(pageIndex, Set(removedIds))
            }

        } else {
            var changed = false
            for i in 0..<current.count { if !strokesMatch(known[i].stroke, current[i]) { changed = true; break } }
            guard changed else { return }
            let oldIds = known.map { $0.id.uuidString }
            var rm = Airpdf_V1_StrokeRemove()
            rm.documentID = documentId; rm.pageIndex = UInt32(pageIndex); rm.strokeIds = oldIds
            onDelta?(.wrap(.strokeRemove(rm)))
            onStrokesRemoved?(pageIndex, Set(oldIds))
            var batch = Airpdf_V1_StrokeBatch()
            batch.documentID = documentId; batch.pageIndex = UInt32(pageIndex)
            var newKnown: [(id: UUID, stroke: PKStroke)] = []
            var newStrokes: [(id: UUID, stroke: PKStroke)] = []
            for stroke in current {
                let uuid = UUID()
                newKnown.append((uuid, stroke)); newStrokes.append((uuid, stroke))
                var entry = Airpdf_V1_StrokeEntry()
                entry.strokeID = uuid.uuidString
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
        return a.transform == b.transform
    }
}
#endif
