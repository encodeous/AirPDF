import PDFKit
import PencilKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Manages per-stroke PDFAnnotation stamps on a single PDFPage.
/// Each finalized stroke is rendered at 8× as a stamp annotation.
///
/// Workaround for Apple bug (https://developer.apple.com/forums/thread/804619):
/// `removeAnnotation` doesn't visually update. So removal is done by stripping
/// all annotations and re-adding survivors — `addAnnotation` always renders.
final class StrokeAnnotationLayer {
    private weak var page: PDFPage?
    /// Stroke data keyed by ID — used to rebuild annotations after removal.
    private var strokes: [String: PKStroke] = [:]
    /// Live annotations on the page keyed by ID.
    private var annotations: [String: PDFAnnotation] = [:]

    init(page: PDFPage) {
        self.page = page
    }

    /// Render a stroke at 8× and add it as a stamp annotation.
    func addStroke(id: String, stroke: PKStroke) {
        guard let page else { return }
        strokes[id] = stroke
        let ann = Self.makeAnnotation(stroke: stroke, page: page)
        guard let ann else { return }
        annotations[id] = ann
        page.addAnnotation(ann)
    }

    /// Remove strokes by ID. Strips all annotations and re-adds survivors
    /// to work around Apple's removeAnnotation display bug.
    func removeStrokes(ids: Set<String>) {
        for id in ids { strokes.removeValue(forKey: id) }
        rebuild()
    }

    /// Remove all managed annotations from the page.
    func removeAll() {
        guard let page else { return }
        for ann in annotations.values { page.removeAnnotation(ann) }
        annotations.removeAll()
        strokes.removeAll()
    }

    var strokeIds: Set<String> { Set(strokes.keys) }
    var isEmpty: Bool { strokes.isEmpty }

    // MARK: - Private

    /// Strip all annotations and re-add from strokes dict.
    private func rebuild() {
        guard let page else { return }
        for ann in annotations.values { page.removeAnnotation(ann) }
        annotations.removeAll()
        for (id, stroke) in strokes {
            if let ann = Self.makeAnnotation(stroke: stroke, page: page) {
                annotations[id] = ann
                page.addAnnotation(ann)
            }
        }
    }

    private static func makeAnnotation(stroke: PKStroke, page: PDFPage) -> StrokeStampAnnotation? {
        let drawing = PKDrawing(strokes: [stroke])
        let pkBounds = drawing.bounds
        guard !pkBounds.isEmpty else { return nil }
        let pageHeight = page.bounds(for: .mediaBox).height
        let pdfDrawingRect = CGRect(
            x: pkBounds.minX,
            y: pageHeight - pkBounds.maxY,
            width: pkBounds.width,
            height: pkBounds.height
        )
        let pdfBounds = pdfDrawingRect.insetBy(dx: -5, dy: -5)
        return StrokeStampAnnotation(drawing: drawing, drawingRect: pdfDrawingRect, bounds: pdfBounds)
    }
}

// MARK: - Stamp annotation with 8× raster appearance

private final class StrokeStampAnnotation: PDFAnnotation {
    #if canImport(UIKit)
    private let image: UIImage
    #elseif canImport(AppKit)
    private let image: NSImage
    #endif
    private let drawingRect: CGRect

    init(drawing: PKDrawing, drawingRect: CGRect, bounds: CGRect) {
        #if canImport(UIKit)
        let traits = UITraitCollection(userInterfaceStyle: .light)
        var rendered: UIImage!
        traits.performAsCurrent {
            rendered = drawing.image(from: drawing.bounds, scale: 8.0)
        }
        self.image = rendered
        #elseif canImport(AppKit)
        var rendered: NSImage!
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            rendered = drawing.image(from: drawing.bounds, scale: 8.0)
        }
        self.image = rendered
        #endif
        self.drawingRect = drawingRect
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var hasAppearanceStream: Bool { true }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        #if canImport(UIKit)
        guard let cgImage = image.cgImage else { return }
        #elseif canImport(AppKit)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        #endif
        context.draw(cgImage, in: drawingRect)
    }
}
