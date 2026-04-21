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
        if vc.currentDocId != doc.id {
            vc.loadDocument(doc)
        }
    }
}

// MARK: - Drawing view controller

private final class CanvasUndoShieldManager: UndoManager {
    var logicalUndoManagerProvider: (() -> UndoManager?)?

    private var logicalUndoManager: UndoManager? {
        logicalUndoManagerProvider?()
    }

    override var canUndo: Bool { logicalUndoManager?.canUndo ?? false }
    override var canRedo: Bool { logicalUndoManager?.canRedo ?? false }

    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {}

    override func undo() {
        logicalUndoManager?.undo()
    }

    override func redo() {
        logicalUndoManager?.redo()
    }
}

private final class AirPDFCanvasView: PKCanvasView {
    private let shieldedUndoManager = CanvasUndoShieldManager()

    var logicalUndoManagerProvider: (() -> UndoManager?)? {
        get { shieldedUndoManager.logicalUndoManagerProvider }
        set { shieldedUndoManager.logicalUndoManagerProvider = newValue }
    }

    override var undoManager: UndoManager? { shieldedUndoManager }
}

final class DrawingViewController: UIViewController {
    var onStrokeDelta: ((Airpdf_V1_SyncEnvelope) -> Void)?
    private(set) var currentDocId: String?

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
    private let logicalUndoManager = UndoManager()

    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { logicalUndoManager }

    /// Register one undo action on the VC's undoManager.
    /// Undo sends Undo to Mac, registers a redo.
    /// Redo sends Redo to Mac, re-registers an undo (so the cycle continues).
    func registerLogicalUndoAction() {
        undoManager?.registerUndo(withTarget: self) { vc in
            vc.onStrokeDelta?(.wrap(.undo({
                var m = Airpdf_V1_Undo()
                m.documentID = vc.overlayCoordinator.docId
                return m
            }())))
            vc.undoManager?.registerUndo(withTarget: vc) { vc2 in
                vc2.onStrokeDelta?(.wrap(.redo({
                    var m = Airpdf_V1_Redo()
                    m.documentID = vc2.overlayCoordinator.docId
                    return m
                }())))
                vc2.registerLogicalUndoAction()
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
        currentDocId = doc.id
        guard isViewLoaded else { pendingDoc = doc; return }
        applyDocument(doc)
    }

    /// Apply a full snapshot from DrawingsUpdate. Rebuilds annotations from model.
    func applySnapshot(_ strokes: [(id: UUID, page: Int, stroke: PKStroke)]) {
        overlayCoordinator.applySnapshot(strokes)
    }

    private func applyDocument(_ doc: TabDocument) {
        let strokes = StrokeModel.decodePageStrokes(doc.pageStrokesProto)
        overlayCoordinator.configure(
            docId: doc.id, initialStrokes: strokes, toolPicker: toolPicker,
            onStrokeDelta: { [weak self] env in self?.onStrokeDelta?(env) }
        )
        overlayCoordinator.onNeedsFirstResponder = { [weak self] in self?.becomeFirstResponder() }
        overlayCoordinator.logicalUndoManagerProvider = { [weak self] in self?.logicalUndoManager }
        overlayCoordinator.onOperationCommitted = { [weak self] in
            self?.registerLogicalUndoAction()
            self?.becomeFirstResponder()
        }
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
    let model = StrokeModel()
    private var differs: [Int: StrokeDiffer] = [:]
    private var annotationLayers: [Int: StrokeAnnotationLayer] = [:]
    private(set) var isEditMode = false
    private var pendingEditSetup: [Int: [(id: UUID, stroke: PKStroke)]] = [:]

    var docId = ""
    private weak var toolPicker: PKToolPicker?
    private weak var pdfViewRef: PDFView?
    private var onStrokeDelta: ((Airpdf_V1_SyncEnvelope) -> Void)?
    var logicalUndoManagerProvider: (() -> UndoManager?)?
    var onNeedsFirstResponder: (() -> Void)?
    var onOperationCommitted: (() -> Void)?
    var activeCanvases: [PKCanvasView] { Array(pageToViewMapping.values) }

    func configure(docId: String, initialStrokes: [(id: UUID, page: Int, stroke: PKStroke)],
                   toolPicker: PKToolPicker, onStrokeDelta: @escaping (Airpdf_V1_SyncEnvelope) -> Void) {
        self.docId = docId
        model.replaceAll(with: initialStrokes)
        self.toolPicker = toolPicker
        self.onStrokeDelta = onStrokeDelta
    }

    func reset() {
        for layer in annotationLayers.values { layer.removeAll() }
        pageToViewMapping = [:]
        differs = [:]
        annotationLayers = [:]
        pendingEditSetup = [:]
        isEditMode = false
        model.clear()
    }

    // MARK: - Stroke commit (from StrokeDiffer after pen lift)

    func commitNewStrokes(pageIndex: Int, newStrokes: [(id: UUID, stroke: PKStroke)], changeID: String?) {
        guard !newStrokes.isEmpty else { return }
        model.addStrokes(newStrokes.map { (id: $0.id, page: pageIndex, stroke: $0.stroke) }, changeID: changeID)
        guard !isEditMode else { return }
        if let layer = annotationLayer(for: pageIndex) {
            for (id, stroke) in newStrokes { layer.addStroke(id: id.uuidString, stroke: stroke) }
        }
        differs[pageIndex]?.clearKnown()
        clearCanvas(pageIndex: pageIndex)
    }

    func handleStrokesRemoved(pageIndex: Int, ids: Set<UUID>, changeID: String?) {
        model.removeStrokes(ids: ids, changeID: changeID)
        if !isEditMode {
            annotationLayers[pageIndex]?.removeStrokes(ids: Set(ids.map { $0.uuidString }))
        }
    }

    // MARK: - Remote snapshot (DrawingsUpdate from Mac)

    func applySnapshot(_ strokes: [(id: UUID, page: Int, stroke: PKStroke)]) {
        model.replaceAll(with: strokes)
        if isEditMode {
            rebuildEditModeCanvases()
        } else {
            rebuildAllAnnotations()
        }
    }

    private func rebuildAllAnnotations() {
        // Remove all existing annotations
        for layer in annotationLayers.values { layer.removeAll() }
        annotationLayers.removeAll()

        // Rebuild from model for all visible pages
        var pagesToInvalidate: [(PDFPage, Int)] = []
        for (page, _) in pageToViewMapping {
            guard let doc = page.document else { continue }
            let idx = doc.index(for: page)
            let layer = StrokeAnnotationLayer(page: page)
            annotationLayers[idx] = layer
            for (id, stroke) in model.activeStrokes(forPage: idx) {
                layer.addStroke(id: id.uuidString, stroke: stroke)
            }
            differs[idx]?.clearKnown()
            pagesToInvalidate.append((page, idx))
        }

        // Page re-insert to force visual refresh
        let scrollView = pdfViewRef?.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView
        let savedOffset = scrollView?.contentOffset
        for (page, idx) in pagesToInvalidate {
            guard let doc = page.document else { continue }
            doc.removePage(at: idx); doc.insert(page, at: idx)
        }
        if let savedOffset { scrollView?.contentOffset = savedOffset }
        onNeedsFirstResponder?()
    }

    private func rebuildEditModeCanvases() {
        for layer in annotationLayers.values { layer.removeAll() }
        pendingEditSetup = [:]

        for (page, canvas) in pageToViewMapping {
            guard let doc = page.document else { continue }
            let idx = doc.index(for: page)
            rehydrateEditCanvas(canvas, pageIndex: idx, strokes: model.activeStrokes(forPage: idx))
        }

        onNeedsFirstResponder?()
    }

    // MARK: - Edit mode

    func enterEditMode() {
        guard !isEditMode else { return }
        isEditMode = true
        var pagesToInvalidate: [(PDFPage, Int)] = []
        for (page, _) in pageToViewMapping {
            guard let doc = page.document else { continue }
            let idx = doc.index(for: page)
            let strokes = model.activeStrokes(forPage: idx)
            guard !strokes.isEmpty else { continue }
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
            // Surviving strokes after edit are already tracked in model via handleStrokesRemoved
            if let layer = annotationLayer(for: idx) {
                for (id, stroke) in model.activeStrokes(forPage: idx) {
                    layer.addStroke(id: id.uuidString, stroke: stroke)
                }
            }
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

    private func rehydrateEditCanvas(_ canvas: PKCanvasView, pageIndex: Int, strokes: [(id: UUID, stroke: PKStroke)]) {
        guard let differ = differs[pageIndex] else { return }
        canvas.delegate = nil
        canvas.drawing = PKDrawing(strokes: strokes.map(\.stroke))
        let canvasStrokes = canvas.drawing.strokes
        if canvasStrokes.count == strokes.count {
            let paired = zip(strokes, canvasStrokes).map { ($0.0.id, $0.1) }
            differ.restoreKnown(paired)
        } else {
            differ.restoreKnown(strokes)
        }
        canvas.delegate = differ
    }

    // MARK: - Helpers

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

    // MARK: - PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let doc = view.document else { return nil }
        let idx = doc.index(for: page)
        pdfViewRef = view

        if let existing = pageToViewMapping[page] {
            return existing
        }

        let canvas = AirPDFCanvasView(frame: .zero)
        canvas.drawingPolicy = .pencilOnly
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.logicalUndoManagerProvider = logicalUndoManagerProvider
        if let tool = toolPicker?.selectedTool { canvas.tool = tool }

        let differ: StrokeDiffer
        if let existing = differs[idx] {
            differ = existing
        } else {
            differ = StrokeDiffer(pageIndex: idx, documentId: docId)
            differ.onDelta = { [weak self] env in self?.onStrokeDelta?(env) }
            differs[idx] = differ
        }
        differ.onStrokesAdded = { [weak self] pi, ns, changeID in
            self?.commitNewStrokes(pageIndex: pi, newStrokes: ns, changeID: changeID)
        }
        differ.onStrokesRemoved = { [weak self] pi, ids, changeID in
            self?.handleStrokesRemoved(pageIndex: pi, ids: ids, changeID: changeID)
        }
        differ.onOperationCommitted = { [weak self] _ in self?.onOperationCommitted?() }

        if let editStrokes = pendingEditSetup.removeValue(forKey: idx) {
            // Edit mode: put strokes on canvas for PencilKit tools to operate on
            canvas.drawing = PKDrawing(strokes: editStrokes.map { $0.stroke })
            let canvasStrokes = canvas.drawing.strokes
            let paired: [(id: UUID, stroke: PKStroke)]
            if canvasStrokes.count == editStrokes.count {
                paired = zip(editStrokes, canvasStrokes).map { ($0.0.id, $0.1) }
            } else {
                paired = editStrokes
            }
            differ.restoreKnown(paired)
        } else if annotationLayers[idx] == nil {
            // First time seeing this page — build annotations from model
            let layer = StrokeAnnotationLayer(page: page)
            annotationLayers[idx] = layer
            let strokes = model.activeStrokes(forPage: idx)
            // If eraser/lasso already active, go straight to edit mode
            let currentToolNeedsEdit = toolPicker.map {
                $0.selectedToolItem is PKToolPickerEraserItem || $0.selectedToolItem is PKToolPickerLassoItem
            } ?? false
            if currentToolNeedsEdit && !strokes.isEmpty {
                isEditMode = true
                canvas.drawing = PKDrawing(strokes: strokes.map { $0.stroke })
                let canvasStrokes = canvas.drawing.strokes
                let paired: [(id: UUID, stroke: PKStroke)]
                if canvasStrokes.count == strokes.count {
                    paired = zip(strokes, canvasStrokes).map { ($0.0.id, $0.1) }
                } else {
                    paired = strokes
                }
                differ.restoreKnown(paired)
            } else {
                for (id, stroke) in strokes { layer.addStroke(id: id.uuidString, stroke: stroke) }
                differ.clearKnown()
            }
        } else {
            // Annotation layer already exists (e.g. page re-insert for visual refresh)
            differ.clearKnown()
        }

        canvas.delegate = differ
        toolPicker?.addObserver(canvas)
        pageToViewMapping[page] = canvas
        logger.info("overlayViewFor page \(idx): created canvas")
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {}

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        toolPicker?.removeObserver(canvas)
        pageToViewMapping.removeValue(forKey: page)
    }
}

// MARK: - Stroke differ (simplified: always uses randomSeed)

final class StrokeDiffer: NSObject, PKCanvasViewDelegate {
    let pageIndex: Int
    let documentId: String
    var onDelta: ((Airpdf_V1_SyncEnvelope) -> Void)?
    var onStrokesAdded: ((_ pageIndex: Int, _ newStrokes: [(id: UUID, stroke: PKStroke)], _ changeID: String?) -> Void)?
    var onStrokesRemoved: ((_ pageIndex: Int, _ removedIds: Set<UUID>, _ changeID: String?) -> Void)?
    var onOperationCommitted: ((_ changeID: String) -> Void)?

    /// randomSeed → (UUID, PKStroke) mapping. Source of truth for stroke identity.
    private var known: [UInt32: (id: UUID, stroke: PKStroke)] = [:]

    init(pageIndex: Int, documentId: String) {
        self.pageIndex = pageIndex
        self.documentId = documentId
        super.init()
    }

    func clearKnown() { known = [:] }

    func restoreKnown(_ strokes: [(id: UUID, stroke: PKStroke)]) {
        known = [:]
        for (id, stroke) in strokes {
            known[stroke.randomSeed] = (id: id, stroke: stroke)
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        let current = canvasView.drawing.strokes
        let currentBySeed = Dictionary(uniqueKeysWithValues: current.map { ($0.randomSeed, $0) })
        let currentSeeds = Set(current.map { $0.randomSeed })
        let knownSeeds = Set(known.keys)
        let modifiedSeeds = currentSeeds.intersection(knownSeeds).filter { seed in
            guard let knownStroke = known[seed]?.stroke,
                  let currentStroke = currentBySeed[seed] else { return false }
            return !strokesMatch(knownStroke, currentStroke)
        }
        let hasChanges = currentSeeds != knownSeeds || !modifiedSeeds.isEmpty
        let changeID = hasChanges ? UUID().uuidString : nil

        // Removed or modified strokes: remove old identity first.
        let removedSeeds = knownSeeds.subtracting(currentSeeds).union(modifiedSeeds)
        if !removedSeeds.isEmpty {
            var removedIds: [UUID] = []
            var removedIdStrings: [String] = []
            for seed in removedSeeds {
                if let entry = known.removeValue(forKey: seed) {
                    removedIds.append(entry.id)
                    removedIdStrings.append(entry.id.uuidString)
                }
            }
            var rm = Airpdf_V1_StrokeRemove()
            rm.documentID = documentId; rm.pageIndex = UInt32(pageIndex)
            rm.strokeIds = removedIdStrings
            if let changeID { rm.changeID = changeID }
            onDelta?(.wrap(.strokeRemove(rm)))
            onStrokesRemoved?(pageIndex, Set(removedIds), changeID)
        }

        // New or modified strokes: add current geometry back with fresh IDs.
        let newSeeds = currentSeeds.subtracting(knownSeeds).union(modifiedSeeds)
        if !newSeeds.isEmpty {
            var batch = Airpdf_V1_StrokeBatch()
            batch.documentID = documentId; batch.pageIndex = UInt32(pageIndex)
            var newStrokes: [(id: UUID, stroke: PKStroke)] = []
            for stroke in current where newSeeds.contains(stroke.randomSeed) {
                let uuid = UUID()
                known[stroke.randomSeed] = (id: uuid, stroke: stroke)
                newStrokes.append((id: uuid, stroke: stroke))
                var entry = Airpdf_V1_StrokeEntry()
                entry.strokeID = uuid.uuidString
                entry.pkStrokeData = PKDrawing(strokes: [stroke]).dataRepresentation()
                batch.strokes.append(entry)
            }
            if let changeID { batch.changeID = changeID }
            onDelta?(.wrap(.strokeBatch(batch)))
            onStrokesAdded?(pageIndex, newStrokes, changeID)
        }

        if let changeID {
            onOperationCommitted?(changeID)
        }
    }

    private func strokesMatch(_ lhs: PKStroke, _ rhs: PKStroke) -> Bool {
        let lhsData = PKDrawing(strokes: [lhs]).dataRepresentation()
        let rhsData = PKDrawing(strokes: [rhs]).dataRepresentation()
        return lhsData == rhsData
    }
}
#endif
