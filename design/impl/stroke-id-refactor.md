# Stroke ID Refactor

## Status: Complete

## Problem

The current architecture has two independent ID spaces:
- **Mac**: `strokeLog[(id, page, stroke)]` with UUIDs for strokes received from iPad, but disk-loaded strokes use synthetic `disk_N_N` positional IDs
- **iPad**: `StrokeDiffer.known[(id, stroke)]` with UUIDs for new strokes, but baseline strokes (loaded from `PdfData.page_drawings`) get fresh UUIDs assigned by position

These two spaces never agree on IDs for disk-loaded strokes, so `StrokeRemove` messages from the iPad (erase) can't be matched on the Mac.

## Solution

One UUID per stroke, born when drawn, persisted forever. Same ID on wire, on disk, in memory.

## Proto Changes

### New message
```proto
message PageStrokes {
  repeated StrokeEntry strokes = 1;
}
```
Reuses existing `StrokeEntry { string stroke_id = 1; bytes pk_stroke_data = 2; }`.

### PdfData
- Remove `map<uint32, bytes> page_drawings = 5`
- Add `map<uint32, PageStrokes> page_strokes = 7`

### DrawingsUpdate
- Remove `map<uint32, bytes> page_drawings = 2`
- Add `map<uint32, PageStrokes> page_strokes = 3`

`StrokeBatch`, `StrokeRemove`, `StrokeEntry` — unchanged.

## Disk Format

Replace `airpdf_drawing.pkdata` file attachment with `airpdf_strokes.pb` — binary protobuf `PageStrokes` per page.

- **Save**: build `PageStrokes` from `strokeLog[0..<undoIndex]` for each page, serialize to protobuf bytes, store as file attachment annotation named `airpdf_strokes.pb`
- **Load**: read `airpdf_strokes.pb`, deserialize as `PageStrokes`, decode each `StrokeEntry.pk_stroke_data` as `PKDrawing(data:).strokes.first` → `strokeLog[(UUID, page, PKStroke)]`
- **Stamp annotations** for visual fidelity: built from decoded strokes at save time (unchanged)
- **Fallback**: if `airpdf_strokes.pb` absent (old file), page has no editable strokes

## Mac Changes

### DocumentSession
- Remove `pageDrawings: [Int: Data]`
- Remove `baseDrawings: [Int: PKDrawing]`
- Remove `strokeId(page:index:)`
- `strokeLog` is the sole source of truth for all stroke state

### init / reloadFromDisk
- Read `airpdf_strokes.pb` per page → deserialize `PageStrokes` → populate `strokeLog` with original UUIDs
- `savedUndoIndex = undoIndex` after loading (no unsaved changes)

### makePdfData
- Build `page_strokes: [UInt32: PageStrokes]` from `strokeLog[0..<undoIndex]` grouped by page
- Each `StrokeEntry`: `stroke_id = entry.id.uuidString`, `pk_stroke_data = PKDrawing(strokes:[entry.stroke]).dataRepresentation()`

### makeDrawingsUpdate
- Same as `makePdfData` but only `page_strokes`, no PDF bytes

### saveSelectedPDF
- Write `airpdf_strokes.pb` per page (replaces `airpdf_drawing.pkdata`)
- Build `PKDrawing` from active strokes for stamp annotations (visual fidelity, unchanged)
- Strip old `airpdf_strokes.pb` and `Stamp` annotations before writing new ones

### PDFStripper
- Strip `airpdf_strokes.pb` attachments (replaces stripping `airpdf_drawing.pkdata`)

## iPad Changes

### TabDocument
- Replace `pageDrawings: [Int: Data]` with `pageStrokes: [Int: [(id: UUID, stroke: PKStroke)]]`

### DocumentStore
- `receive(_:)`: decode `msg.pageStrokes` → for each page, decode each `StrokeEntry` → `(UUID(uuidString: entry.strokeID)!, PKDrawing(data: entry.pkStrokeData).strokes.first!)` → store as `pageStrokes`
- `applyDrawingsUpdate(_:)`: same decoding from `DrawingsUpdate.pageStrokes`

### OverlayCoordinator
- `configure(docId:pageStrokes:toolPicker:onStrokeDelta:)` — takes `[Int: [(UUID, PKStroke)]]`
- `pageDrawings: [Int: Data]` → replaced by `pageStrokes: [Int: [(id: UUID, stroke: PKStroke)]]`
- `committedStrokes` type: `[Int: [(id: UUID, stroke: PKStroke)]]`
- `applyRemoteDrawingUpdate(pageIndex:entries:[(UUID, PKStroke)])` — takes decoded strokes directly

### StrokeDiffer
- `init(pageIndex:documentId:baseline:[(id:UUID, stroke:PKStroke)])` — takes pairs directly
- `known: [(id: UUID, stroke: PKStroke)]`
- New strokes: `UUID()` assigned on draw
- Edit mode matching: `randomSeed` → UUID (unchanged)
- Remove `resetBaseline`, `disk_N_N` scheme

### ConnectionViewModel
- `handleMessage(.drawingsUpdate)`: decode `PageStrokes` → `[(UUID, PKStroke)]` per page, pass to `applyRemoteDrawingUpdate`

## Deleted
- `DocumentSession.pageDrawings`
- `DocumentSession.baseDrawings`
- `DocumentSession.strokeId(page:index:)`
- `AppModel.updateDrawing`
- `OverlayCoordinator.pageDrawings: [Int: Data]`
- `StrokeDiffer.resetBaseline`
- `TabDocument.pageDrawings`
- All `disk_N_N` positional ID generation
- `airpdf_drawing.pkdata` attachment (replaced by `airpdf_strokes.pb`)

## Data Flow

```
iPad draws
  → UUID born in StrokeDiffer
  → StrokeBatch(uuid.uuidString, pkdata) → Mac
  → Mac: strokeLog.append((uuid, page, stroke))

Mac saves
  → per page: PageStrokes{[(uuid, pkdata)]} → airpdf_strokes.pb attachment

Mac loads from disk
  → airpdf_strokes.pb → PageStrokes → strokeLog[(uuid, page, stroke)]
  → savedUndoIndex = undoIndex

Mac sends PdfData
  → page_strokes[page] = PageStrokes{[(uuid, pkdata)]}

iPad receives PdfData
  → decode PageStrokes → [(UUID, PKStroke)] per page
  → StrokeDiffer.known = [(uuid, stroke)] directly
  → PKDrawing built from strokes for canvas
  → annotations built from (uuid, stroke) pairs

iPad erases
  → randomSeed matching → canonical UUID recovered
  → StrokeRemove(uuid.uuidString) → Mac
  → Mac: strokeLog.removeAll { $0.id == uuid } ✓
  → Mac: annotation removed by uuid ✓
```

## UUID Type

- Swift: `UUID` throughout internal code
- Proto boundary: `.uuidString` on encode, `UUID(uuidString:)!` on decode
- Annotation layer keys: `String` (UUID.uuidString) — unchanged

## Implementation Notes

### Additional fixes discovered during implementation

**Spurious StrokeRemove on overlay recreation**
`overlayViewFor` fires multiple times per page (on initial load, after `clearCanvas`, after edit mode page re-insert). On subsequent calls, `annotationLayers[idx]` already exists so `clearKnown()` was skipped — leaving `differ.known` non-zero while the canvas was empty. Fixed by always calling `differ.clearKnown()` when not entering edit mode, regardless of whether the annotation layer already exists.

**Delegate assigned before clearKnown**
`canvas.delegate = differ` was set before `differ.clearKnown()`, so PDFKit could fire `canvasViewDrawingDidChange` with `current=0 known=N` during canvas insertion. Fixed by moving `canvas.delegate = differ` to after all setup (annotation layer creation, `clearKnown`, edit mode restore).

**Edit mode not entered when eraser already selected on load**
`toolPickerSelectedToolItemDidChange` only fires on tool *change*, not on document load. If the eraser was already selected, `enterEditMode` was never called. Fixed in `overlayViewFor`: when creating a new canvas, if the current tool is eraser/lasso and there are strokes, `isEditMode = true` and `pendingEditSetup` is populated directly — bypassing the annotation path and going straight to canvas restore.

**Mac live document retaining saved annotations**
`loadStrokesFromDisk` read `airpdf_strokes.pb` attachments but left them (and old `Stamp` annotations) on the live `PDFDocument`. `rebuildAnnotations` then added new stamp annotations on top, causing `annotations=17` instead of the expected count. Fixed by stripping `airpdf_strokes.pb`, `airpdf_drawing.pkdata`, and `Stamp` annotations from the live document inside `loadStrokesFromDisk`.

**rebuildAnnotations not visually refreshing**
`rebuildAnnotations` stripped and re-added annotations via `addAnnotation` (which works), but never called `invalidatePage`. Since `removeAnnotation` is buggy, the page showed stale visuals. Fixed by calling `invalidatePage` for each page after rebuilding.

**Redo crash (EXC_BREAKPOINT / stack overflow)**
`registerUndoAction` registered a redo closure that called `registerUndoAction` recursively, building an unbounded chain. Spamming redo caused a stack overflow. Fixed by removing the recursive call — each stroke registers exactly one undo→redo pair.

### Files modified

| File | Change |
|------|--------|
| `proto/airpdf.proto` | Added `PageStrokes` message; replaced `page_drawings: map<uint32, bytes>` with `page_strokes: map<uint32, PageStrokes>` in `PdfData` and `DrawingsUpdate` |
| `Sources/macOS/DocumentSession.swift` | Removed `pageDrawings`, `baseDrawings`, `strokeId()`; `strokeLog` uses `UUID`; `loadStrokesFromDisk` reads `airpdf_strokes.pb` and strips all AirPDF annotations from live document |
| `Sources/macOS/AppModel.swift` | `strokeLog` uses `UUID`; `makePdfData`/`makeDrawingsUpdate` build `page_strokes`; `saveSelectedPDF` writes `airpdf_strokes.pb`; removed `updateDrawing` |
| `Sources/macOS/MacPDFView.swift` | `rebuildAnnotationsForPage` uses `UUID.uuidString`; `rebuildAnnotations` calls `invalidatePage` per page; `makeNSView` calls `rebuildAnnotations` after wiring coordinator |
| `Sources/Core/PDFStripper.swift` | Strips `airpdf_strokes.pb` and `airpdf_drawing.pkdata` (backward compat) |
| `Sources/iPad/DocumentStore.swift` | `TabDocument.pageStrokes: [Int: [(UUID, PKStroke)]]`; `receive`/`applyDrawingsUpdate` decode `PageStrokes`; manual `Equatable`/`Hashable` on `TabDocument` |
| `Sources/iPad/PDFCanvasView.swift` | `StrokeDiffer` takes `[(UUID, PKStroke)]` baseline; all IDs are `UUID`; `OverlayCoordinator` uses `pageStrokes`; delegate deferred until after setup; auto edit mode on load; `registerUndoAction` non-recursive |
| `Sources/iPad/ConnectionViewModel.swift` | `drawingsUpdate` decodes `PageStrokes` → `[(UUID, PKStroke)]` before routing |
