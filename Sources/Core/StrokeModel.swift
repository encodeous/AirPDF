import Foundation
import PDFKit
import PencilKit
import SwiftProtobuf

/// Shared stroke model used by both Mac and iPad.
/// `strokeLog` stores the current active strokes in display order.
/// Undo/redo is tracked separately as a log of logical operations.
final class StrokeModel {
    struct Entry {
        let id: UUID
        let page: Int
        let stroke: PKStroke
    }

    private struct RemovedEntry {
        let entry: Entry
        let activeIndex: Int
    }

    private struct Operation {
        var changeID: String?
        var added: [Entry]
        var removed: [RemovedEntry]
    }

    private(set) var strokeLog: [Entry] = []
    private(set) var undoIndex: Int = 0
    var savedUndoIndex: Int = 0

    private var operationLog: [Operation] = []

    var hasUnsavedChanges: Bool { undoIndex != savedUndoIndex }
    var canUndo: Bool { undoIndex > 0 }
    var canRedo: Bool { undoIndex < operationLog.count }

    // MARK: - Queries

    func activeStrokes(forPage page: Int) -> [(id: UUID, stroke: PKStroke)] {
        strokeLog
            .filter { $0.page == page }
            .map { (id: $0.id, stroke: $0.stroke) }
    }

    func allActiveStrokes() -> [Int: [(id: UUID, stroke: PKStroke)]] {
        var result: [Int: [(id: UUID, stroke: PKStroke)]] = [:]
        for entry in strokeLog {
            result[entry.page, default: []].append((id: entry.id, stroke: entry.stroke))
        }
        return result
    }

    // MARK: - Mutations

    /// Append new strokes. Without a `changeID`, each stroke is its own undo step.
    func addStrokes(_ entries: [(id: UUID, page: Int, stroke: PKStroke)], changeID: String? = nil) {
        let mapped = entries.map { Entry(id: $0.id, page: $0.page, stroke: $0.stroke) }
        guard !mapped.isEmpty else { return }

        if let changeID {
            truncateRedoTailIfNeeded()
            if mergeAdded(mapped, intoOperationWith: changeID) { return }
            record(Operation(changeID: changeID, added: mapped, removed: []))
            strokeLog.append(contentsOf: mapped)
            return
        }

        for entry in mapped {
            truncateRedoTailIfNeeded()
            record(Operation(changeID: nil, added: [entry], removed: []))
            strokeLog.append(entry)
        }
    }

    /// Remove strokes by ID. If a `changeID` is supplied, all removals become one undo step.
    func removeStrokes(ids: Set<UUID>, changeID: String? = nil) {
        guard !ids.isEmpty else { return }
        let removed = removedEntries(for: ids)
        guard !removed.isEmpty else { return }

        if let changeID {
            truncateRedoTailIfNeeded()
            if mergeRemoved(removed, intoOperationWith: changeID) {
                applyRemoval(ids)
                return
            }
            record(Operation(changeID: changeID, added: [], removed: removed))
            applyRemoval(ids)
            return
        }

        record(Operation(changeID: nil, added: [], removed: removed))
        applyRemoval(ids)
    }

    /// Undo one logical operation. Returns the most recently affected entry.
    func undo() -> Entry? {
        guard canUndo else { return nil }
        undoIndex -= 1
        let op = operationLog[undoIndex]
        if !op.added.isEmpty {
            applyRemoval(Set(op.added.map(\.id)))
        }
        if !op.removed.isEmpty {
            restore(op.removed)
        }
        return op.added.last ?? op.removed.last?.entry
    }

    /// Redo one logical operation. Returns the most recently affected entry.
    func redo() -> Entry? {
        guard canRedo else { return nil }
        let op = operationLog[undoIndex]
        if !op.removed.isEmpty {
            applyRemoval(Set(op.removed.map { $0.entry.id }))
        }
        if !op.added.isEmpty {
            strokeLog.append(contentsOf: op.added)
        }
        undoIndex += 1
        return op.added.last ?? op.removed.last?.entry
    }

    /// Replace entire stroke state (used when receiving DrawingsUpdate/PdfData on iPad).
    func replaceAll(with strokes: [(id: UUID, page: Int, stroke: PKStroke)]) {
        strokeLog = strokes.map { Entry(id: $0.id, page: $0.page, stroke: $0.stroke) }
        operationLog = []
        undoIndex = 0
        savedUndoIndex = 0
    }

    func markSaved() { savedUndoIndex = undoIndex }

    func clear() {
        strokeLog = []
        operationLog = []
        undoIndex = 0
        savedUndoIndex = 0
    }

    // MARK: - Disk I/O

    /// Load strokes from airpdf_strokes.pb attachments. Strips AirPDF annotations from the live document.
    func loadFromDisk(pdfDocument: PDFDocument) {
        strokeLog = []
        operationLog = []
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
        undoIndex = 0
    }

    // MARK: - Proto helpers

    /// Build the page_strokes proto map from active strokes.
    func pageStrokesMap() -> [UInt32: Airpdf_V1_PageStrokes] {
        var map: [UInt32: Airpdf_V1_PageStrokes] = [:]
        for entry in strokeLog {
            let key = UInt32(entry.page)
            var ps = map[key] ?? Airpdf_V1_PageStrokes()
            var se = Airpdf_V1_StrokeEntry()
            se.strokeID = entry.id.uuidString
            se.pkStrokeData = PKDrawing(strokes: [entry.stroke]).dataRepresentation()
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

    // MARK: - Helpers

    private func record(_ operation: Operation) {
        operationLog.append(operation)
        undoIndex = operationLog.count
    }

    private func truncateRedoTailIfNeeded() {
        guard undoIndex < operationLog.count else { return }
        if savedUndoIndex > undoIndex {
            savedUndoIndex = undoIndex
        }
        operationLog.removeSubrange(undoIndex...)
    }

    private func mergeAdded(_ entries: [Entry], intoOperationWith changeID: String) -> Bool {
        guard undoIndex == operationLog.count,
              var op = operationLog.last,
              op.changeID == changeID else { return false }
        op.added.append(contentsOf: entries)
        operationLog[operationLog.count - 1] = op
        strokeLog.append(contentsOf: entries)
        return true
    }

    private func mergeRemoved(_ entries: [RemovedEntry], intoOperationWith changeID: String) -> Bool {
        guard undoIndex == operationLog.count,
              var op = operationLog.last,
              op.changeID == changeID else { return false }
        op.removed.append(contentsOf: entries)
        operationLog[operationLog.count - 1] = op
        return true
    }

    private func removedEntries(for ids: Set<UUID>) -> [RemovedEntry] {
        strokeLog.enumerated().compactMap { index, entry in
            ids.contains(entry.id) ? RemovedEntry(entry: entry, activeIndex: index) : nil
        }
    }

    private func applyRemoval(_ ids: Set<UUID>) {
        strokeLog.removeAll { ids.contains($0.id) }
    }

    private func restore(_ removed: [RemovedEntry]) {
        for removedEntry in removed.sorted(by: { $0.activeIndex < $1.activeIndex }) {
            let insertionIndex = min(removedEntry.activeIndex, strokeLog.count)
            strokeLog.insert(removedEntry.entry, at: insertionIndex)
        }
    }
}
