# AirPDF Phase 3 — PencilKit & Drawing Sync

## Status: Complete

## What Was Built

### iPad: Per-Page PKCanvasView Overlays

**`Sources/iPad/PDFCanvasView.swift`:**
- `PDFCanvasView` — `UIViewControllerRepresentable` wrapping `DrawingViewController`.
- `DrawingViewController` — hosts `PDFView` with `isInMarkupMode = true`, owns `PKToolPicker`, acts as first responder anchor for tool picker visibility.
- `OverlayCoordinator` — `NSObject` conforming to `PDFPageOverlayViewProvider` (WWDC 2022 pattern):
  - `overlayViewFor`: creates `PKCanvasView` per page, restores drawing from `pageDrawings`, wires `StrokeDiffer` as delegate, registers with tool picker. Keyed by `PDFPage` object.
  - `willEndDisplayingOverlayView`: saves drawing to `pageDrawings`, removes from map (releases view per WWDC guidelines).
  - `willDisplayOverlayView`: empty (no custom gestures needed).
- `StrokeDiffer` — `PKCanvasViewDelegate` that tracks per-page stroke identity and emits deltas. Persists across overlay recycling (keyed by page index in coordinator).
- Tool picker anchored to the VC (`canBecomeFirstResponder = true`, `becomeFirstResponder()` in `viewDidAppear`), not to any canvas — survives overlay recycling.
- `overrideUserInterfaceStyle = .light` on VC view and canvases; `toolPicker.overrideUserInterfaceStyle = .light` for consistent light-mode rendering on white PDFs.

### iPad: Stroke Diffing & Transmission

**`StrokeDiffer` in `Sources/iPad/PDFCanvasView.swift`:**
- Maintains `known: [(id: String, stroke: PKStroke)]` ordered list matching canvas strokes by position.
- `canvasViewDrawingDidChange` handles three cases:
  - **count > known**: new strokes appended → emit `StrokeBatch`.
  - **count < known**: strokes removed (erase/undo) → emit batched `StrokeRemove` with all removed IDs.
  - **count == known**: strokes modified (lasso move/transform) → detect via `strokesMatch`, emit `StrokeRemove` for all old + `StrokeBatch` for all new.
- `strokesMatch` heuristic: compares `path.count` and `ink.color`.
- `resetBaseline` for PdfData re-send (assigns fresh UUIDs, no deltas emitted).

### Mac: Receive & Display Strokes

**`Sources/macOS/AppModel.swift`:**
- `handleMessage` dispatched on main thread (fixed `ClientConnection` to `DispatchQueue.main.async` before calling `onMessage`).
- `StrokeBatch`: deserializes each `StrokeEntry.pk_stroke_data` as single-stroke `PKDrawing`, appends to in-memory strokes, updates `pageDrawings`, registers undo action.
- `StrokeRemove`: removes strokes by ID from `strokeMetadata`, rebuilds drawing.
- `Undo`/`Redo`: invokes `session.undoManager.undo()`/`.redo()`.
- `updateDrawing`: updates `session.pageDrawings[page]`, calls `session.overlayCoordinator?.refreshOverlays()` directly (bypasses SwiftUI update coalescing).

**`Sources/macOS/MacPDFView.swift`:**
- `MacPDFView` — `NSViewRepresentable` with `PDFPageOverlayViewProvider` via `MacOverlayCoordinator`.
- `MacOverlayCoordinator`: provides `DrawingOverlayView` per page, keyed by `PDFPage`.
- `DrawingOverlayView` — `NSView` subclass, `isOpaque = false`, renders `PKDrawing.image(from:scale:)` in `draw(_:)`.
- `refreshOverlays()`: updates each overlay's `drawing` from `session.pageDrawings` and calls `needsDisplay = true`.

### Mac: PDF Persistence

**`Sources/macOS/DocumentSession.swift`:**
- On open: reads `airpdf_drawing.pkdata` file attachment annotations per page → populates `pageDrawings`.
- Added `strokeMetadata: [Int: [String: PKStroke]]`, `undoManager`, `pdfViewRef`, `overlayCoordinator`.

**`Sources/Core/PDFStripper.swift`:**
- Strips `Ink`, `Stamp`, and `FileAttachment` (pkdata) annotations from a copy before transmission.

**`Sources/macOS/StrokeAnnotation.swift`:**
- `DrawingAnnotation` — `PDFAnnotation` subclass (`.stamp` type) with `draw(with:in:)` override that renders `PKDrawing.image()` into the appearance stream. Used at save time only.

**`Sources/macOS/AppModel.swift` — `saveSelectedPDF()`:**
- Writes `airpdf_drawing.pkdata` file attachment annotation per page with `PKDrawing.dataRepresentation()`.
- Save/Undo/Redo toolbar buttons in `ContentView`.

### Proto Changes

**`proto/airpdf.proto`:**
- `StrokeRemove.stroke_id` (field 3, singular) → `StrokeRemove.stroke_ids` (field 4, `repeated string`). Batches multiple removals in one message.

### UI Fixes

- `ConnectionView`: extracted `ClientStateView` with `@ObservedObject var client: QuicClient` to fix nested `ObservableObject` stale render.
- `PDFTabView`: added `.id(doc.id)` on `PDFCanvasView` to force recreation on tab switch.
- Connected state: `.navigationTitle("").navigationBarTitleDisplayMode(.inline)` — removes "AirPDF" title over PDF while keeping toolbar buttons.
- iPad Undo/Redo toolbar buttons forward `Undo`/`Redo` messages to Mac.

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| `PDFPageOverlayViewProvider` for iPad canvases | Official API (WWDC 2022); handles positioning, sizing, rotation, recycling automatically |
| Tool picker anchored to VC, not canvases | VC is always in window hierarchy; survives overlay recycling without flicker |
| `PDFPageOverlayViewProvider` for Mac display too | Same pattern; `DrawingOverlayView` renders PKDrawing image per page |
| `DrawingAnnotation` (stamp) for save, not ink | Ink annotations render stroked outlines; stamp with `draw(with:in:)` override renders filled appearance stream matching PKCanvasView |
| `StrokeRemove` batched (`repeated stroke_ids`) | Efficient for lasso move (remove all + re-add all) and multi-erase |
| Light mode forced on canvases + tool picker | Most PDFs are white; prevents white-on-white strokes in dark mode |
| Direct `refreshOverlays()` call, not SwiftUI flag | SwiftUI coalesces `objectWillChange`; direct call ensures every stroke update renders immediately |
| `ClientConnection.onMessage` dispatched to main | `AppModel.handleMessage` mutates PDFDocument and @Published properties; must run on main thread |

## Known Limitations

- **PKCanvasView blurry on zoom**: confirmed Apple framework limitation (DTS engineer response). PKCanvasView inherits UIScrollView; backing store doesn't re-rasterize at zoom scale. No workaround exists.
- **Mac overlay is raster**: `DrawingOverlayView` uses `PKDrawing.image()` which is raster at screen scale. Vector rendering (walking PKStrokePath + NSBezierPath) deferred to Phase 4.
- **Undo/redo not fully wired for iPad feedback**: Mac processes undo but doesn't yet send StrokeRemove/StrokeBatch back to iPad to update its canvas.

## Files Created

| File | Purpose |
|------|---------|
| `Sources/iPad/PDFCanvasView.swift` | Per-page PKCanvasView overlays, StrokeDiffer, tool picker management |
| `Sources/macOS/StrokeAnnotation.swift` | DrawingAnnotation for PDF save (stamp with PKDrawing appearance) |

## Files Modified

| File | Change |
|------|--------|
| `Sources/Core/PDFStripper.swift` | Real stripping: Ink + Stamp + pkdata FileAttachment |
| `Sources/macOS/DocumentSession.swift` | Reads pkdata on open; added strokeMetadata, undoManager, pdfViewRef, overlayCoordinator |
| `Sources/macOS/AppModel.swift` | StrokeBatch/StrokeRemove/Undo/Redo handling; updateDrawing; saveSelectedPDF |
| `Sources/macOS/MacPDFView.swift` | PDFPageOverlayViewProvider with DrawingOverlayView for Mac display |
| `Sources/macOS/ContentView.swift` | Save/Undo/Redo toolbar buttons; passes session to MacPDFView |
| `Sources/iPad/PDFTabView.swift` | Uses PDFCanvasView; accepts onStrokeDelta callback; .id(doc.id) |
| `Sources/iPad/ConnectionView.swift` | ClientStateView extraction; Undo/Redo buttons; empty nav title when connected |
| `Sources/iPad/ConnectionViewModel.swift` | send() and sendUndoRedo() methods |
| `Sources/macOS/Networking/ClientConnection.swift` | onMessage dispatched to main thread |
| `proto/airpdf.proto` | StrokeRemove: stroke_id → repeated stroke_ids |
