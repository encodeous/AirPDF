#if os(macOS)
import PDFKit
import PencilKit
import AppKit

/// Renders a PKDrawing as a stamp annotation on a PDF page.
/// Uses the WWDC 2022 approach: draw the PKDrawing image into the annotation's appearance stream.
final class DrawingAnnotation: PDFAnnotation {
    let drawing: PKDrawing

    init(drawing: PKDrawing, bounds: CGRect) {
        self.drawing = drawing
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

        let image = drawing.image(from: drawing.bounds, scale: 2.0)
        image.draw(in: drawing.bounds)

        NSGraphicsContext.restoreGraphicsState()
    }
}

extension PKStroke {
    /// Creates a simple stamp annotation that renders the stroke visually.
    static func toPDFAnnotation(_ stroke: PKStroke, page: PDFPage) -> PDFAnnotation {
        let drawing = PKDrawing(strokes: [stroke])
        let bounds = drawing.bounds.insetBy(dx: -5, dy: -5)
        return DrawingAnnotation(drawing: drawing, bounds: bounds)
    }
}
#endif
