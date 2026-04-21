@testable import AirPDF
import XCTest
import PencilKit
import PDFKit
import SwiftProtobuf

final class StrokeModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeStroke() -> PKStroke {
        let ink = PKInk(.pen, color: .black)
        let points = [
            PKStrokePoint(location: CGPoint(x: 10, y: 10), timeOffset: 0, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: 50, y: 50), timeOffset: 0.1, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKStroke(ink: ink, path: path)
    }

    private func makeEntry(page: Int = 0) -> (id: UUID, page: Int, stroke: PKStroke) {
        (id: UUID(), page: page, stroke: makeStroke())
    }

    // MARK: - Basic state

    func testEmptyModel() {
        let model = StrokeModel()
        XCTAssertEqual(model.strokeLog.count, 0)
        XCTAssertEqual(model.undoIndex, 0)
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertTrue(model.allActiveStrokes().isEmpty)
    }

    // MARK: - addStrokes

    func testAddStrokes() {
        let model = StrokeModel()
        model.addStrokes([makeEntry(page: 0), makeEntry(page: 1)])
        XCTAssertEqual(model.strokeLog.count, 2)
        XCTAssertEqual(model.undoIndex, 2)
        XCTAssertTrue(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    func testAddStrokesTruncatesRedoTail() {
        let model = StrokeModel()
        let e1 = makeEntry()
        let e2 = makeEntry()
        let e3 = makeEntry()
        model.addStrokes([e1, e2, e3])
        _ = model.undo()
        _ = model.undo()

        let e4 = makeEntry()
        model.addStrokes([e4])
        XCTAssertEqual(model.strokeLog.count, 2)
        XCTAssertEqual(model.undoIndex, 2)
        XCTAssertFalse(model.canRedo)
        XCTAssertEqual(model.strokeLog[0].id, e1.id)
        XCTAssertEqual(model.strokeLog[1].id, e4.id)
    }

    // MARK: - removeStrokes

    func testRemoveStrokes() {
        let model = StrokeModel()
        let e1 = makeEntry()
        let e2 = makeEntry()
        let e3 = makeEntry()
        model.addStrokes([e1, e2, e3])
        model.removeStrokes(ids: [e2.id])
        XCTAssertEqual(model.strokeLog.count, 2)
        XCTAssertEqual(model.strokeLog[0].id, e1.id)
        XCTAssertEqual(model.strokeLog[1].id, e3.id)
    }

    func testRemoveStrokesClampsUndoIndex() {
        let model = StrokeModel()
        let e1 = makeEntry()
        let e2 = makeEntry()
        model.addStrokes([e1, e2])
        model.removeStrokes(ids: [e1.id, e2.id])
        XCTAssertEqual(model.strokeLog.count, 0)
        XCTAssertEqual(model.undoIndex, 3)
        XCTAssertTrue(model.canUndo)
    }

    func testRemoveNonexistentStroke() {
        let model = StrokeModel()
        model.addStrokes([makeEntry()])
        model.removeStrokes(ids: [UUID()])
        XCTAssertEqual(model.strokeLog.count, 1)
    }

    // MARK: - Undo / Redo

    func testUndoRedo() {
        let model = StrokeModel()
        let e1 = makeEntry()
        let e2 = makeEntry()
        model.addStrokes([e1, e2])

        let undone = model.undo()
        XCTAssertEqual(undone?.id, e2.id)
        XCTAssertEqual(model.undoIndex, 1)
        XCTAssertTrue(model.canUndo)
        XCTAssertTrue(model.canRedo)

        let undone2 = model.undo()
        XCTAssertEqual(undone2?.id, e1.id)
        XCTAssertFalse(model.canUndo)
        XCTAssertTrue(model.canRedo)

        XCTAssertNil(model.undo())

        let redone = model.redo()
        XCTAssertEqual(redone?.id, e1.id)
        XCTAssertTrue(model.canUndo)
        XCTAssertTrue(model.canRedo)

        let redone2 = model.redo()
        XCTAssertEqual(redone2?.id, e2.id)
        XCTAssertFalse(model.canRedo)

        XCTAssertNil(model.redo())
    }

    func testUndoRedoCycle() {
        let model = StrokeModel()
        let e1 = makeEntry()
        model.addStrokes([e1])

        for _ in 0..<5 {
            let undone = model.undo()
            XCTAssertEqual(undone?.id, e1.id)
            XCTAssertFalse(model.canUndo)
            XCTAssertTrue(model.canRedo)
            XCTAssertEqual(model.activeStrokes(forPage: 0).count, 0)

            let redone = model.redo()
            XCTAssertEqual(redone?.id, e1.id)
            XCTAssertTrue(model.canUndo)
            XCTAssertFalse(model.canRedo)
            XCTAssertEqual(model.activeStrokes(forPage: 0).count, 1)
        }
    }

    func testUndoAllThenRedoAll() {
        let model = StrokeModel()
        let entries = (0..<5).map { _ in makeEntry() }
        model.addStrokes(entries)

        for i in (0..<5).reversed() {
            XCTAssertEqual(model.undo()?.id, entries[i].id)
        }
        XCTAssertFalse(model.canUndo)
        XCTAssertEqual(model.activeStrokes(forPage: 0).count, 0)

        for i in 0..<5 {
            XCTAssertEqual(model.redo()?.id, entries[i].id)
        }
        XCTAssertFalse(model.canRedo)
        XCTAssertEqual(model.activeStrokes(forPage: 0).count, 5)
    }

    // MARK: - Multi-page

    func testMultiPageActiveStrokes() {
        let model = StrokeModel()
        model.addStrokes([makeEntry(page: 0), makeEntry(page: 1), makeEntry(page: 0), makeEntry(page: 1), makeEntry(page: 2)])
        XCTAssertEqual(model.activeStrokes(forPage: 0).count, 2)
        XCTAssertEqual(model.activeStrokes(forPage: 1).count, 2)
        XCTAssertEqual(model.activeStrokes(forPage: 2).count, 1)
        XCTAssertEqual(model.activeStrokes(forPage: 3).count, 0)
        XCTAssertEqual(model.allActiveStrokes().count, 3)
    }

    func testUndoMultiPage() {
        let model = StrokeModel()
        model.addStrokes([makeEntry(page: 0), makeEntry(page: 1)])
        let undone = model.undo()
        XCTAssertEqual(undone?.page, 1)
        XCTAssertEqual(model.activeStrokes(forPage: 0).count, 1)
        XCTAssertEqual(model.activeStrokes(forPage: 1).count, 0)
    }

    // MARK: - replaceAll

    func testReplaceAll() {
        let model = StrokeModel()
        model.addStrokes([makeEntry(), makeEntry()])
        _ = model.undo()

        let e3 = makeEntry(page: 1)
        model.replaceAll(with: [e3])
        XCTAssertEqual(model.strokeLog.count, 1)
        XCTAssertEqual(model.undoIndex, 0)
        XCTAssertEqual(model.strokeLog[0].id, e3.id)
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testReplaceAllEmpty() {
        let model = StrokeModel()
        model.addStrokes([makeEntry(), makeEntry()])
        model.replaceAll(with: [])
        XCTAssertEqual(model.strokeLog.count, 0)
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)
    }

    // MARK: - clear

    func testClear() {
        let model = StrokeModel()
        model.addStrokes([makeEntry(), makeEntry()])
        model.markSaved()
        model.addStrokes([makeEntry()])
        model.clear()
        XCTAssertEqual(model.strokeLog.count, 0)
        XCTAssertEqual(model.undoIndex, 0)
        XCTAssertEqual(model.savedUndoIndex, 0)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    // MARK: - hasUnsavedChanges / markSaved

    func testHasUnsavedChanges() {
        let model = StrokeModel()
        XCTAssertFalse(model.hasUnsavedChanges)
        model.addStrokes([makeEntry()])
        XCTAssertTrue(model.hasUnsavedChanges)
        model.markSaved()
        XCTAssertFalse(model.hasUnsavedChanges)
        _ = model.undo()
        XCTAssertTrue(model.hasUnsavedChanges)
        _ = model.redo()
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    // MARK: - Proto round-trip

    func testPageStrokesMapRoundTrip() {
        let model = StrokeModel()
        let e1 = makeEntry(page: 0)
        let e2 = makeEntry(page: 0)
        let e3 = makeEntry(page: 1)
        model.addStrokes([e1, e2, e3])

        let protoMap = model.pageStrokesMap()
        XCTAssertEqual(protoMap.count, 2)
        XCTAssertEqual(protoMap[0]?.strokes.count, 2)
        XCTAssertEqual(protoMap[1]?.strokes.count, 1)

        let decoded = StrokeModel.decodePageStrokes(protoMap)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].id, e1.id)
        XCTAssertEqual(decoded[1].id, e2.id)
        XCTAssertEqual(decoded[2].id, e3.id)
    }

    func testPageStrokesMapRespectsUndoIndex() {
        let model = StrokeModel()
        model.addStrokes([makeEntry(), makeEntry(), makeEntry()])
        _ = model.undo()
        _ = model.undo()
        let total = model.pageStrokesMap().values.reduce(0) { $0 + $1.strokes.count }
        XCTAssertEqual(total, 1)
    }

    func testPageStrokesMapEmptyAfterFullUndo() {
        let model = StrokeModel()
        model.addStrokes([makeEntry()])
        _ = model.undo()
        XCTAssertTrue(model.pageStrokesMap().isEmpty)
    }

    func testDecodePageStrokesEmpty() {
        XCTAssertTrue(StrokeModel.decodePageStrokes([:]).isEmpty)
    }

    // MARK: - Disk I/O round-trip

    func testLoadFromDiskRoundTrip() {
        let pdfDoc = PDFDocument()
        let page = PDFPage()
        pdfDoc.insert(page, at: 0)

        let id1 = UUID()
        let id2 = UUID()
        var ps = Airpdf_V1_PageStrokes()
        var se1 = Airpdf_V1_StrokeEntry()
        se1.strokeID = id1.uuidString
        se1.pkStrokeData = (try? PKDrawing(strokes: [makeStroke()]).dataRepresentation()) ?? Data()
        var se2 = Airpdf_V1_StrokeEntry()
        se2.strokeID = id2.uuidString
        se2.pkStrokeData = (try? PKDrawing(strokes: [makeStroke()]).dataRepresentation()) ?? Data()
        ps.strokes = [se1, se2]

        if let pbData = try? ps.serializedData() {
            let att = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    forType: PDFAnnotationSubtype(rawValue: "/FileAttachment"), withProperties: nil)
            att.contents = "airpdf_strokes.pb"
            att.setValue(pbData, forAnnotationKey: PDFAnnotationKey(rawValue: "/FS"))
            page.addAnnotation(att)
        }
        let stamp = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), forType: .stamp, withProperties: nil)
        page.addAnnotation(stamp)
        XCTAssertEqual(page.annotations.count, 2)

        let model = StrokeModel()
        model.loadFromDisk(pdfDocument: pdfDoc)

        XCTAssertEqual(model.strokeLog.count, 2)
        XCTAssertEqual(model.undoIndex, 0)
        XCTAssertFalse(model.canUndo)
        XCTAssertEqual(model.strokeLog[0].id, id1)
        XCTAssertEqual(model.strokeLog[1].id, id2)
        XCTAssertEqual(page.annotations.count, 0) // stripped
    }

    func testLoadFromDiskEmpty() {
        let pdfDoc = PDFDocument()
        pdfDoc.insert(PDFPage(), at: 0)
        let model = StrokeModel()
        model.loadFromDisk(pdfDocument: pdfDoc)
        XCTAssertEqual(model.strokeLog.count, 0)
    }

    func testLoadFromDiskMultiPage() {
        let pdfDoc = PDFDocument()
        pdfDoc.insert(PDFPage(), at: 0)
        let page1 = PDFPage()
        pdfDoc.insert(page1, at: 1)

        let id = UUID()
        var ps = Airpdf_V1_PageStrokes()
        var se = Airpdf_V1_StrokeEntry()
        se.strokeID = id.uuidString
        se.pkStrokeData = (try? PKDrawing(strokes: [makeStroke()]).dataRepresentation()) ?? Data()
        ps.strokes = [se]
        if let pbData = try? ps.serializedData() {
            let att = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                    forType: PDFAnnotationSubtype(rawValue: "/FileAttachment"), withProperties: nil)
            att.contents = "airpdf_strokes.pb"
            att.setValue(pbData, forAnnotationKey: PDFAnnotationKey(rawValue: "/FS"))
            page1.addAnnotation(att)
        }

        let model = StrokeModel()
        model.loadFromDisk(pdfDocument: pdfDoc)
        XCTAssertEqual(model.strokeLog.count, 1)
        XCTAssertEqual(model.strokeLog[0].page, 1)
        XCTAssertEqual(model.activeStrokes(forPage: 0).count, 0)
        XCTAssertEqual(model.activeStrokes(forPage: 1).count, 1)
    }

    // MARK: - Full scenarios

    func testMacUndoRedoScenario() {
        let model = StrokeModel()
        let s1 = makeEntry(page: 0)
        let s2 = makeEntry(page: 0)
        let s3 = makeEntry(page: 1)
        model.addStrokes([s1])
        model.addStrokes([s2])
        model.addStrokes([s3])

        XCTAssertEqual(model.undo()?.id, s3.id)
        XCTAssertEqual(model.undo()?.id, s2.id)
        XCTAssertEqual(model.redo()?.id, s2.id)

        XCTAssertEqual(model.activeStrokes(forPage: 0).count, 2)
        XCTAssertEqual(model.activeStrokes(forPage: 1).count, 0)

        let protoMap = model.pageStrokesMap()
        XCTAssertEqual(protoMap.count, 1)
        XCTAssertNil(protoMap[1])
    }

    func testIPadSnapshotReplace() {
        let model = StrokeModel()
        model.addStrokes([makeEntry(page: 0), makeEntry(page: 1)])

        let new1 = makeEntry(page: 0)
        model.replaceAll(with: [new1])
        XCTAssertEqual(model.strokeLog.count, 1)
        XCTAssertEqual(model.activeStrokes(forPage: 1).count, 0)
        XCTAssertFalse(model.canRedo)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testIPadSnapshotReplaceEmpty() {
        let model = StrokeModel()
        model.addStrokes([makeEntry(), makeEntry()])
        model.replaceAll(with: [])
        XCTAssertEqual(model.strokeLog.count, 0)
        XCTAssertFalse(model.canUndo)
    }

    func testRemoveStrokeThenUndo() {
        let model = StrokeModel()
        let e1 = makeEntry()
        let e2 = makeEntry()
        model.addStrokes([e1, e2])
        model.removeStrokes(ids: [e1.id])
        let undone = model.undo()
        XCTAssertEqual(undone?.id, e1.id)
        XCTAssertEqual(model.activeStrokes(forPage: 0).count, 2)
    }

    func testGroupedRemoveAndAddUndoRedo() {
        let model = StrokeModel()
        let original = makeEntry()
        model.replaceAll(with: [original])

        let moved = makeEntry()
        model.removeStrokes(ids: [original.id], changeID: "lasso")
        model.addStrokes([moved], changeID: "lasso")

        XCTAssertEqual(model.undoIndex, 1)
        XCTAssertEqual(model.activeStrokes(forPage: 0).map(\.id), [moved.id])

        _ = model.undo()
        XCTAssertEqual(model.activeStrokes(forPage: 0).map(\.id), [original.id])

        _ = model.redo()
        XCTAssertEqual(model.activeStrokes(forPage: 0).map(\.id), [moved.id])
    }
}
