#if os(macOS)
import PDFKit
import PencilKit
import AppKit

/// Renders a PKDrawing as a stamp annotation.
/// Uses a high-resolution raster image in the appearance stream.
/// PencilKit does not expose a synchronous vector rendering API,
/// so we render at high scale for crisp output at all zoom levels.
final class DrawingAnnotation: PDFAnnotation {
    private let image: NSImage

    init(drawing: PKDrawing, bounds: CGRect) {
        var rendered: NSImage!
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            rendered = drawing.image(from: drawing.bounds, scale: 8.0)
        }
        self.image = rendered
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var hasAppearanceStream: Bool { true }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
}
#endif
