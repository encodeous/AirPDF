# Live Annotation-Based Stroke Rendering

## Status: Complete

## Problem

Both the Mac overlay (`DrawingOverlayView` rendering `PKDrawing.image()` at screen scale) and the iPad `PKCanvasView` produce blurry strokes when zoomed. The 8× raster `DrawingAnnotation` stamps (used at save time) are crisp at all zoom levels but were only written to the PDF file on save.

## Solution

Replace overlay-based rendering with live `PDFAnnotation` stamps (8× raster) immediately after pen-lift on both platforms. The `PKCanvasView` overlay is only used for the in-progress stroke while the pencil is touching the screen. Eraser/lasso tools temporarily restore strokes to the canvas for PencilKit to operate on.

## Architecture

### Two display modes

1. **Drawing mode** (default): Canvas is empty. Finalized strokes are 8× stamp annotations on the `PDFPage`. User sees annotations.
2. **Edit mode** (eraser/lasso active): Annotations are removed. Strokes are restored to the canvas. PencilKit tools operate on canvas strokes. On exit, surviving strokes become annotations again.

### StrokeAnnotationLayer (Sources/Core)

Shared type managing per-stroke annotations on a single `PDFPage`. Both platforms use it.

- `addStroke(id:stroke:)` — renders at 8×, adds annotation to page. Stores stroke in internal dict for rebuild.
- `removeStrokes(ids:)` — removes from internal dict, then **rebuilds** (strips all annotations, re-adds survivors). This works around the Apple `removeAnnotation` display bug.
- `removeAll()` — strips all annotations and clears internal state.
- `rebuild()` — private. Strips all annotations from page, re-adds from internal strokes dict. The key workaround: `addAnnotation` always renders correctly, `removeAnnotation` does not.

### Coordinate conversion

PencilKit uses top-left origin (Y down). PDF annotations use bottom-left origin (Y up). Conversion:
```
pdfY = pageHeight - pkBounds.maxY
```

The annotation `bounds` include 5pt padding for hit-testing. The image is drawn into `drawingRect` (exact PencilKit bounds converted to PDF coords), not the padded `bounds`. This prevents small strokes from being stretched.

### Rendering

`StrokeStampAnnotation` (private) renders via `CGContext.draw(cgImage, in: drawingRect)`. Using `CGImage` directly avoids UIImage/NSImage coordinate flip issues — `CGContext.draw` natively uses bottom-left origin matching PDF space.

## iPad Implementation

### Drawing flow

1. Pen lifts → `canvasViewDrawingDidChange` fires (stroke count increased)
2. `StrokeDiffer` detects new strokes, emits `StrokeBatch` to Mac
3. `onStrokesAdded` callback → `commitStrokesToAnnotations`:
   - Adds each stroke to `StrokeAnnotationLayer`
   - Updates `committedStrokes[pageIndex]` (authoritative list of annotation-managed strokes)
   - Clears `differ.known` (canvas is now empty)
   - Clears canvas drawing (delegate nil during clear to prevent spurious delta)
4. User sees: 8× annotation on PDF page. Canvas is transparent.

### Edit mode (eraser/lasso)

**Enter** (`enterEditMode`):
1. Set `isEditMode = true`
2. For each visible page with committed strokes:
   - `annotationLayer.removeAll()` — strips annotations from data model
   - Store strokes in `pendingEditSetup[pageIndex]`
3. Page re-insert (`doc.removePage` + `doc.insert`) forces PDFKit to visually clear the removed annotations AND tears down the overlay
4. Save/restore scroll position via `UIScrollView.contentOffset` (not `currentDestination` which has an offset bug on iOS)
5. `overlayViewFor` fires (overlay recreation). Detects `pendingEditSetup[idx]`:
   - Sets `canvas.delegate = nil` before setting `canvas.drawing` (prevents spurious delta)
   - Sets canvas drawing from stored strokes
   - Re-reads `canvas.drawing.strokes` and pairs with original IDs (PencilKit may modify stroke objects)
   - Calls `differ.restoreKnown(paired)` and `differ.isEditMode = true`
   - Sets `canvas.delegate = differ`

**During edit** (erase/lasso):
- `canvasViewDrawingDidChange` fires. In edit mode, stroke identity uses `PKStroke.randomSeed` (a `UInt32` unique per stroke) instead of `strokesMatch` (which is unreliable on restored strokes).
- `onStrokesRemoved` → `removeStrokeAnnotations`: only updates `committedStrokes` (annotations are already removed). Does NOT touch annotation layer during edit mode.
- `onDelta` sends `StrokeRemove` to Mac as normal.

**Exit** (`exitEditMode`):
1. Set `isEditMode = false`
2. Read surviving strokes from `differ.knownStrokes`
3. Update `committedStrokes` and `pageDrawings`
4. Re-add surviving strokes as annotations (adding always works visually)
5. Clear canvas and differ

### StrokeDiffer changes

- `knownStrokes` — read-only accessor for the `known` list
- `clearKnown()` — empties `known` (canvas was cleared, strokes moved to annotations)
- `restoreKnown(_:)` — sets `known` from provided strokes (edit mode entry)
- `isEditMode` flag — switches removal matching from `strokesMatch` to `randomSeed`-based fingerprinting
- `onStrokesAdded` / `onStrokesRemoved` callbacks — notify coordinator to manage annotations

### Tool picker

Custom `PKToolPicker(toolItems:)` with:
- Default inking tools
- Vector-only eraser (`PKToolPickerEraserItem(type: .vector)`) — no bitmap/pixel eraser. Inserted before lasso tool.
- Lasso, ruler, etc.

Bitmap eraser is disabled because it splits strokes (partial erasure), which breaks our whole-stroke annotation model.

Edit mode triggers on `PKToolPickerEraserItem` or `PKToolPickerLassoItem`.

## Mac Implementation

### MacAnnotationCoordinator (replaces MacOverlayCoordinator)

No overlay provider needed. `MacPDFView` no longer sets `pageOverlayViewProvider`. Annotations are the sole display layer.

- `addStrokeAnnotation(page:id:stroke:)` — adds via annotation layer
- `removeStrokeAnnotations(page:ids:)` — removes via annotation layer, then `invalidatePage` (page re-insert with scroll position save/restore via `currentDestination`)
- `rebuildAnnotations()` — removes all, re-adds from `strokeLog` + `baseDrawings`
- `invalidatePage(_:)` — `doc.removePage(at:)` + `doc.insert(page, at:)` with `currentDestination` save/restore

### AppModel changes

- `strokeBatch`: adds annotation for each new stroke via `overlayCoordinator.addStrokeAnnotation`
- `strokeRemove`: removes annotations via `overlayCoordinator.removeStrokeAnnotations`
- `handleUndo`: removes undone stroke's annotation
- `handleRedo`: adds redone stroke's annotation
- `saveSelectedPDF`: strips live annotations (`removeAllAnnotations`), adds save-time `DrawingAnnotation` stamps + pkdata, writes file, strips save-time stamps, rebuilds live annotations

## Apple Bugs Worked Around

### 1. `removeAnnotation` display bug
**Bug**: `PDFPage.removeAnnotation()` removes from data model but doesn't visually update the `PDFView`. Confirmed by DTS Engineer (Oct 2025): https://developer.apple.com/forums/thread/804619

**Workaround (Mac)**: Page re-insert — `doc.removePage(at:)` + `doc.insert(page, at:)`. Scroll position preserved via `pdfView.currentDestination` / `pdfView.go(to:)`.

**Workaround (iPad edit mode)**: Page re-insert with scroll position preserved via `UIScrollView.contentOffset`. The overlay is recreated by PDFKit; `pendingEditSetup` defers canvas setup to `overlayViewFor`.

**Workaround (iPad annotation layer)**: `StrokeAnnotationLayer.removeStrokes` uses rebuild pattern — strips all annotations, re-adds survivors. `addAnnotation` always renders correctly.

### 2. PencilKit stroke identity loss on restore
**Bug**: Strokes programmatically set on `PKCanvasView` via `canvas.drawing = PKDrawing(strokes:)` lose internal PencilKit identity. `strokesMatch` (comparing `path.count`, `ink.color`, `transform`) fails on restored strokes. PencilKit logs "retrieving stroke identifier gave nil or invalid result."

**Workaround**: In edit mode, use `PKStroke.randomSeed` (a `UInt32` unique per stroke) as the fingerprint for matching surviving strokes after erase/lasso operations. This is order-independent and survives PencilKit's internal modifications.

### 3. `currentDestination` / `go(to:)` offset on iOS
**Bug**: `PDFView.go(to: pdfView.currentDestination)` doesn't restore the exact scroll position on iOS — it shifts down slightly.

**Workaround**: Save/restore the `UIScrollView.contentOffset` from PDFView's first scroll view subview instead.

## Files Created

| File | Purpose |
|------|---------|
| `Sources/Core/StrokeAnnotationLayer.swift` | Shared per-page annotation map + 8× stamp rendering + rebuild workaround |

## Files Modified

| File | Change |
|------|--------|
| `Sources/iPad/PDFCanvasView.swift` | `OverlayCoordinator`: annotation layers, `committedStrokes`, edit mode (enter/exit with page re-insert), `pendingEditSetup`. `StrokeDiffer`: `knownStrokes`, `clearKnown`, `restoreKnown`, `isEditMode`, `randomSeed` matching, `onStrokesAdded`/`onStrokesRemoved`. Custom `PKToolPicker` with vector-only eraser. |
| `Sources/macOS/MacPDFView.swift` | Replaced `MacOverlayCoordinator` (overlay provider) with `MacAnnotationCoordinator` (no overlay). Page re-insert for removal with scroll preserve. `rebuildAnnotations` from strokeLog + baseDrawings. |
| `Sources/macOS/DocumentSession.swift` | `overlayCoordinator` type changed to `MacAnnotationCoordinator` |
| `Sources/macOS/AppModel.swift` | `strokeBatch`/`strokeRemove`/undo/redo manage annotation layers. `saveSelectedPDF` strips live annotations before save, rebuilds after. |

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| Per-stroke annotations (not per-page) | Granular add/remove without re-rendering entire page |
| `CGContext.draw(cgImage:)` for rendering | Avoids UIImage/NSImage coordinate flip issues in PDF annotation context |
| `drawingRect` separate from annotation `bounds` | Prevents small strokes from being stretched into padded bounds |
| `randomSeed` for edit mode stroke matching | Only reliable fingerprint after PencilKit modifies restored strokes |
| Page re-insert for visual refresh | Only known workaround for Apple's `removeAnnotation` display bug |
| `UIScrollView.contentOffset` on iPad | `currentDestination`/`go(to:)` has offset bug on iOS |
| Vector-only eraser | Bitmap eraser splits strokes, breaking whole-stroke annotation model |
| Edit mode = eraser + lasso | Both tools need strokes on canvas to operate |
| `committedStrokes` dict | Authoritative list of annotation-managed strokes; needed for edit mode restore since `differ.known` is cleared |
| `pendingEditSetup` dict | Defers canvas setup to `overlayViewFor` callback after page re-insert tears down overlay |
