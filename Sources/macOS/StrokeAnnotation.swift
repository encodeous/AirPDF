#if os(macOS)
import PDFKit
import PencilKit
import AppKit

extension PKStroke {
    /// Converts a PKStroke to a PDF ink annotation with a filled outline path
    /// that visually matches the variable-width PencilKit rendering.
    static func toPDFInkAnnotation(_ stroke: PKStroke, page: PDFPage) -> PDFAnnotation {
        let path = stroke.filledOutlinePath()
        let bounds = path.bounds.insetBy(dx: -2, dy: -2)
        let ann = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        ann.color = NSColor(cgColor: stroke.ink.color.cgColor ?? NSColor.black.cgColor) ?? .black
        // Translate path to annotation-local coordinates
        let localPath = NSBezierPath()
        let transform = AffineTransform(translationByX: -bounds.minX, byY: -bounds.minY)
        localPath.append(path)
        localPath.transform(using: transform)
        ann.add(localPath)
        return ann
    }

    /// Builds a filled outline NSBezierPath from the stroke's variable-width path.
    func filledOutlinePath() -> NSBezierPath {
        let sp = self.path
        guard sp.count > 0 else { return NSBezierPath() }

        var leftPoints: [CGPoint] = []
        var rightPoints: [CGPoint] = []

        let count = sp.count
        for i in 0..<count {
            let pt = sp.interpolatedPoint(at: CGFloat(i) / CGFloat(max(count - 1, 1)))
            let halfW = max(pt.size.width, pt.size.height) / 2.0
            // Compute tangent
            let tangent: CGVector
            if i < count - 1 {
                let next = sp.interpolatedPoint(at: CGFloat(i + 1) / CGFloat(max(count - 1, 1)))
                tangent = CGVector(dx: next.location.x - pt.location.x,
                                   dy: next.location.y - pt.location.y)
            } else if i > 0 {
                let prev = sp.interpolatedPoint(at: CGFloat(i - 1) / CGFloat(max(count - 1, 1)))
                tangent = CGVector(dx: pt.location.x - prev.location.x,
                                   dy: pt.location.y - prev.location.y)
            } else {
                tangent = CGVector(dx: 1, dy: 0)
            }
            let len = sqrt(tangent.dx * tangent.dx + tangent.dy * tangent.dy)
            let normal = len > 0 ? CGVector(dx: -tangent.dy / len, dy: tangent.dx / len) : CGVector(dx: 0, dy: 1)
            leftPoints.append(CGPoint(x: pt.location.x + normal.dx * halfW,
                                      y: pt.location.y + normal.dy * halfW))
            rightPoints.append(CGPoint(x: pt.location.x - normal.dx * halfW,
                                       y: pt.location.y - normal.dy * halfW))
        }

        let path = NSBezierPath()
        path.move(to: leftPoints[0])
        for p in leftPoints.dropFirst() { path.line(to: p) }
        for p in rightPoints.reversed() { path.line(to: p) }
        path.close()
        return path
    }
}
#endif
