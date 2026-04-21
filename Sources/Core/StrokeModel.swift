import Foundation
import PDFKit
import PencilKit
import SwiftProtobuf

/// Shared stroke model used by both Mac and iPad.
/// Holds an ordered stroke log with an undo cursor.
/// Mac: source of truth. iPad: mirror populated from PdfData/DrawingsUpdate.
final class StrokeModel {
    struct Entry {
        let id: UUID
        let page: Int
        let stroke: PKStroke
    }

    private(set) var strokeLog: [Entry] = []
    private(set) var undoIndex: Int = 0
    var savedUndoIndex: Int = 0

    var hasUnsavedChanges: Bool { undoIndex != savedUndoIndex }
    var canUndo: Bool { undoIndex > 0 }
    var canRedo: Bool { undoIndex < strokeLog.count }

    // MARK: - Queries

    func activeStrokes(forPage page: Int) -> [(id: UUID, stroke: PKStroke)] {
        strokeLog[0..<undoIndex]
            .filter { $0.page == page }
            .map { (id: $0.id, stroke: $0.stroke) }
    }

    func allActiveStrokes() -> [Int: [(id: UUID, stroke: PKStroke)]] {
        var result: [Int: [(id: UUID, stroke: PKStroke)]] = [:]
        for entry in strokeLog[0..<undoIndex] {
            result[entry.page, default: []].append((id: entry.id, stroke: entry.stroke))
        }
        return result
    }

    // MARK: - Mutations

    /// Append new strokes, truncating any redo tail.
    func addStrokes(_ entries: [(id: UUID, page: Int, stroke: PKStroke)]) {
        strokeLog.removeSubrange(undoIndex...)
        for e in entries {
            strokeLog.append(Entry(id: e.id, page: e.page, stroke: e.stroke))
        }
        undoIndex = strokeLog.count
    }

    /// Remove strokes by ID (erase). Clamps undoIndex.
    func removeStrokes(ids: Set<UUID>) {
        strokeLog.removeAll { ids.contains($0.id) }
        undoIndex = min(undoIndex, strokeLog.count)
    }

    /// Undo one stroke. Returns the undone entry, or nil if nothing to undo.
    func undo() -> Entry? {
        guard canUndo else { return nil }
        undoIndex -= 1
        return strokeLog[undoIndex]
    }

    /// Redo one stroke. Returns the redone entry, or nil if nothing to redo.
    func redo() -> Entry? {
        guard canRedo else { return nil }
        let entry = strokeLog[undoIndex]
        undoIndex += 1
        return entry
    }

    /// Replace entire stroke state (used when receiving DrawingsUpdate/PdfData on iPad).
    func replaceAll(with strokes: [(id: UUID, page: Int, stroke: PKStroke)]) {
        strokeLog = strokes.map { Entry(id: $0.id, page: $0.page, stroke: $0.stroke) }
        undoIndex = strokeLog.count
        savedUndoIndex = undoIndex
    }

    func markSaved() { savedUndoIndex = undoIndex }

    func clear() {
        strokeLog = []
        undoIndex = 0
        savedUndoIndex = 0
    }

    // MARK: - Disk I/O

    /// Load strokes from airpdf_strokes.pb attachments. Strips AirPDF annotations from the live document.
    func loadFromDisk(pdfDocument: PDFDocument) {
        strokeLog = []
        for i in 0..<pdfDocument.pageCount {
            guard let page = pdfDocument.page(at: i) else { continue }
            var toRemove: [PDFAnnotation] = []
            for ann in page.annotations {
                if ann.type == "FileAttachment" &&
                    (ann.contents == "airpdf_strokes.pb" || ann.contents == "airpdf_drawing.pkdata") {
                    if ann.contents == "airpdf_strokes.pb",
                       let data = ann.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/FS")) as? Data,
                       let pageStrokes = try? Airpdf_V1_PageStrokes(serializedBytes: data) {
                        for entry in pageStrokes.strokes {
                            guard let uuid = UUID(uuidString: entry.strokeID),
                                  let drawing = try? PKDrawing(data: entry.pkStrokeData),
                                  let stroke = drawing.strokes.first else { continue }
                            strokeLog.append(Entry(id: uuid, page: i, stroke: stroke))
                        }
                    }
                    toRemove.append(ann)
                } else if ann.type == "Stamp" {
                    toRemove.append(ann)
                }
            }
            toRemove.forEach { page.removeAnnotation($0) }
        }
        undoIndex = strokeLog.count
    }

    // MARK: - Proto helpers

    /// Build the page_strokes proto map from active strokes.
    func pageStrokesMap() -> [UInt32: Airpdf_V1_PageStrokes] {
        var map: [UInt32: Airpdf_V1_PageStrokes] = [:]
        for entry in strokeLog[0..<undoIndex] {
            let key = UInt32(entry.page)
            var ps = map[key] ?? Airpdf_V1_PageStrokes()
            var se = Airpdf_V1_StrokeEntry()
            se.strokeID = entry.id.uuidString
            se.pkStrokeData = (try? PKDrawing(strokes: [entry.stroke]).dataRepresentation()) ?? Data()
            ps.strokes.append(se)
            map[key] = ps
        }
        return map
    }

    /// Decode a proto page_strokes map into flat entries.
    static func decodePageStrokes(_ map: [UInt32: Airpdf_V1_PageStrokes]) -> [(id: UUID, page: Int, stroke: PKStroke)] {
        var result: [(id: UUID, page: Int, stroke: PKStroke)] = []
        for (pageKey, ps) in map.sorted(by: { $0.key < $1.key }) {
            for entry in ps.strokes {
                guard let uuid = UUID(uuidString: entry.strokeID),
                      let drawing = try? PKDrawing(data: entry.pkStrokeData),
                      let stroke = drawing.strokes.first else { continue }
                result.append((id: uuid, page: Int(pageKey), stroke: stroke))
            }
        }
        return result
    }
}
