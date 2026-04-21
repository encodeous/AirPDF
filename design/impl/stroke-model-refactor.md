# Shared Stroke Model Refactor

## Status: Complete

## Problem

The previous architecture had duplicated stroke state across Mac and iPad:
- **Mac**: `DocumentSession.strokeLog`, `undoIndex`, `savedUndoIndex`
- **iPad**: `TabDocument.pageStrokes`, `OverlayCoordinator.committedStrokes`, `OverlayCoordinator.pageStrokes`, `StrokeDiffer.known` (ordered array)

These copies drifted apart, causing three bugs:
1. **Undo desync**: `DrawingsUpdate` merged into `TabDocument.pageStrokes` instead of replacing. Pages cleared by undo (absent from the proto map) were never cleared on iPad.
2. **Undo→redo→undo broken**: The redo closure didn't re-register an undo action, so after redo the undo button was permanently disabled.
3. **`swift_getObjectType` crash**: `.id(doc)` in `PDFTabView` used `TabDocument`'s full hash (including stroke IDs). Every `DrawingsUpdate` changed the hash → SwiftUI destroyed and recreated the `DrawingViewController`. Stale `NSUndoManager` closures referencing the old VC caused a use-after-free crash.

Additionally, `StrokeDiffer` had two separate diffing strategies (ordered-array matching for drawing mode, `randomSeed` matching for edit mode) adding unnecessary complexity.

## Solution

One `StrokeModel` class in `Sources/Core` used by both platforms. Mac and iPad instantiate the same model with identical logic. Platform-specific code (annotations, canvas, PDFKit workarounds) reads from the model and reacts to changes.

## New file: `Sources/Core/StrokeModel.swift`

Shared stroke model holding an ordered stroke log with an undo cursor.

### Properties
- `strokeLog: [Entry]` — ordered log of all strokes (active + redo tail)
- `undoIndex: Int` — cursor; active strokes = `strokeLog[0..<undoIndex]`
- `savedUndoIndex: Int` — tracks disk state for unsaved-changes detection
- `hasUnsavedChanges`, `canUndo`, `canRedo` — computed

### Mutations
- `addStrokes(_:)` — truncates redo tail, appends, advances `undoIndex`
- `removeStrokes(ids:)` — removes by ID (erase), clamps `undoIndex`
- `undo() -> Entry?` — decrements `undoIndex`, returns undone entry
- `redo() -> Entry?` — increments `undoIndex`, returns redone entry
- `replaceAll(with:)` — full state replacement (iPad receives `DrawingsUpdate`)
- `clear()` — resets everything
- `markSaved()` — sets `savedUndoIndex = undoIndex`

### Disk I/O
- `loadFromDisk(pdfDocument:)` — reads `airpdf_strokes.pb` attachments, populates log, strips AirPDF annotations from live document

### Proto helpers
- `pageStrokesMap()` — builds `[UInt32: PageStrokes]` from active strokes
- `decodePageStrokes(_:)` — static, decodes proto map into flat `[(id, page, stroke)]`

## Mac changes

### DocumentSession
- Replaced `strokeLog`, `undoIndex`, `savedUndoIndex`, `loadStrokesFromDisk` with `let model = StrokeModel()`
- `hasUnsavedChanges` delegates to `model.hasUnsavedChanges`
- `init` calls `model.loadFromDisk(pdfDocument:)` then `model.markSaved()`

### AppModel
- `handleMessage(.strokeBatch)`: decodes entries, calls `session.model.addStrokes(_:)`
- `handleMessage(.strokeRemove)`: calls `session.model.removeStrokes(ids:)`
- `handleUndo`: calls `session.model.undo()`, sends only `DrawingsUpdate` (no longer sends `StrokeRemove` + `DrawingsUpdate`)
- `handleRedo`: calls `session.model.redo()`, sends only `DrawingsUpdate` (no longer sends `StrokeBatch` + `DrawingsUpdate`)
- `pageStrokesMap` moved to `StrokeModel`
- `saveSelectedPDF`: uses `model.allActiveStrokes()`, calls `model.markSaved()`

### MacPDFView
- `rebuildAnnotationsForPage` reads from `session.model.activeStrokes(forPage:)`

## iPad changes

### StrokeDiffer (simplified)
- **Removed**: `isEditMode` flag, `strokesMatch` helper, ordered `known` array
- `known` is now `[UInt32: (id: UUID, stroke: PKStroke)]` — a `randomSeed → (UUID, stroke)` map
- `canvasViewDrawingDidChange` compares `randomSeed` sets:
  - Seeds in current but not known → new strokes, assign `UUID()`, emit `StrokeBatch`
  - Seeds in known but not current → removed strokes, emit `StrokeRemove`
  - No equal-count branch needed — seed comparison handles all cases
- `restoreKnown(_:)` builds the seed map from `[(UUID, PKStroke)]` pairs
- `clearKnown()` empties the map

### OverlayCoordinator
- Owns a `StrokeModel` instance (set during `configure`)
- **Removed**: `pageStrokes`, `committedStrokes` dictionaries, `applyRemoteStrokeBatch`, `applyRemoteStrokeRemove`, `applyRemoteDrawingUpdate`
- `commitNewStrokes(pageIndex:newStrokes:)`: calls `model.addStrokes(...)`, adds annotations, clears canvas
- `handleStrokesRemoved(pageIndex:ids:)`: calls `model.removeStrokes(ids:)`, updates annotation layer
- `applySnapshot(_:)`: calls `model.replaceAll(with:)`, rebuilds all annotations with page re-insert
- `enterEditMode`: reads `model.activeStrokes(forPage:)` for strokes to put on canvas
- `exitEditMode`: reads `model.activeStrokes(forPage:)` to rebuild annotations (removals during edit already went through `handleStrokesRemoved` → model)
- `overlayViewFor`: reads `model.activeStrokes(forPage:)` for baseline

### DrawingViewController
- `registerUndoAction`: redo closure now calls `registerUndoAction()` (re-registers undo after redo, so the undo→redo→undo cycle works)
- `loadDocument`: uses `removeAllActions(withTarget: self)` instead of `removeAllActions()` (only clears this VC's actions)
- `updateUIViewController`: handles doc changes in-place when `currentDocId` differs
- `applySnapshot(_:)`: delegates to `overlayCoordinator.applySnapshot`

### TabDocument
- **Removed**: `pageStrokes` field, custom `Equatable`/`Hashable`
- Added: `pageStrokesProto: [UInt32: Airpdf_V1_PageStrokes]` — raw proto for initial load only
- `Equatable`/`Hashable` based on `id` only

### DocumentStore
- **Removed**: `applyDrawingsUpdate` (stroke state no longer lives in `DocumentStore`)
- **Removed**: `decodePageStrokes` helper (moved to `StrokeModel`)

### PDFTabView
- `.id(doc)` → `.id(doc.id)` — VC only recreated when document identity changes, not when strokes change

### ConnectionViewModel
- `handleMessage(.drawingsUpdate)`: decodes via `StrokeModel.decodePageStrokes`, calls `activeDrawingVC?.applySnapshot(_:)` directly (full replace, not merge into `TabDocument`)
- `handleMessage(.pdfData)`: unchanged — `documentStore.receive(msg)` stores the doc, VC decodes `pageStrokesProto` on load

## Bug fixes

### 1. Undo desync (empty pages never cleared)
**Root cause**: `DrawingsUpdate.pageStrokes` only contains pages with active strokes. `applyDrawingsUpdate` merged into existing `TabDocument.pageStrokes` — pages absent from the message were never cleared.

**Fix**: `DrawingsUpdate` is now a full snapshot replace via `model.replaceAll(with:)`. Pages absent from the message have zero strokes in the decoded list → they're correctly cleared.

### 2. Undo→redo→undo broken
**Root cause**: The redo closure sent `Redo` to Mac but didn't re-register an undo action. After redo, the undo stack was empty and the button was permanently disabled.

**Fix**: Redo closure calls `registerUndoAction()` at the end, re-enabling undo after redo.

### 3. `swift_getObjectType` crash
**Root cause**: `.id(doc)` used `TabDocument`'s full hash (including stroke IDs). Every `DrawingsUpdate` changed the hash → SwiftUI destroyed the old `DrawingViewController` and created a new one. `NSUndoManager` held stale closures referencing the old VC via `withTarget:`.

**Fix**: `.id(doc.id)` — VC is only recreated when the document identity changes. Stroke updates go through `applySnapshot` in-place. Also `removeAllActions(withTarget: self)` instead of `removeAllActions()` for safety.

## Data flow (after refactor)

```
iPad draws stroke
  → StrokeDiffer: randomSeed not in known → UUID born
  → StrokeBatch(uuid, pkdata) → Mac
  → Mac: session.model.addStrokes([(uuid, page, stroke)])
  → Mac: overlayCoordinator.addStrokeAnnotation(...)

iPad undo (tool picker button)
  → NSUndoManager fires registered closure
  → Sends Undo message → Mac
  → Mac: session.model.undo() → entry
  → Mac: overlayCoordinator.removeStrokeAnnotations(...)
  → Mac: sends DrawingsUpdate (full snapshot from model.pageStrokesMap())
  → iPad: ConnectionViewModel.handleMessage(.drawingsUpdate)
  → StrokeModel.decodePageStrokes → activeDrawingVC.applySnapshot
  → OverlayCoordinator: model.replaceAll, rebuildAllAnnotations

iPad redo (tool picker button)
  → NSUndoManager fires redo closure
  → Sends Redo message → Mac
  → Mac: session.model.redo() → entry
  → Mac: overlayCoordinator.addStrokeAnnotation(...)
  → Mac: sends DrawingsUpdate (full snapshot)
  → iPad: same path as undo

Mac saves
  → model.allActiveStrokes() → per page: PageStrokes → airpdf_strokes.pb
  → model.markSaved()

Mac loads from disk
  → model.loadFromDisk(pdfDocument:) → strokeLog populated, annotations stripped
  → model.markSaved()
```

## Tests

26 unit tests in `AirPDFTests/AirPDFTests.swift` covering:
- Empty model state
- `addStrokes` (basic, truncates redo tail)
- `removeStrokes` (basic, clamps undoIndex, nonexistent ID)
- `undo`/`redo` (basic, cycle, undo-all-then-redo-all, past boundaries)
- Multi-page queries (`activeStrokes(forPage:)`, `allActiveStrokes()`)
- `replaceAll` (with strokes, empty)
- `clear`
- `hasUnsavedChanges` / `markSaved`
- Proto round-trip (`pageStrokesMap` → `decodePageStrokes`)
- Proto map respects `undoIndex` (undone strokes excluded)
- Disk I/O round-trip (`loadFromDisk` with `airpdf_strokes.pb` attachment)
- Disk I/O strips annotations (file attachment + stamp)
- Disk I/O multi-page
- Full Mac undo/redo scenario
- Full iPad snapshot replace scenario (including empty)
- Edge case: remove stroke then undo

## Files modified

| File | Change |
|------|--------|
| `Sources/Core/StrokeModel.swift` | **New** — shared stroke model |
| `Sources/macOS/DocumentSession.swift` | Replaced strokeLog/undoIndex/savedUndoIndex with `model: StrokeModel` |
| `Sources/macOS/AppModel.swift` | All stroke ops through `session.model`; undo/redo send only `DrawingsUpdate` |
| `Sources/macOS/MacPDFView.swift` | `rebuildAnnotationsForPage` reads from `session.model` |
| `Sources/iPad/PDFCanvasView.swift` | Rewritten: simplified `StrokeDiffer` (randomSeed always), `OverlayCoordinator` uses `StrokeModel`, fixed `registerUndoAction` |
| `Sources/iPad/DocumentStore.swift` | `TabDocument` simplified (no pageStrokes), removed `applyDrawingsUpdate` |
| `Sources/iPad/PDFTabView.swift` | `.id(doc)` → `.id(doc.id)` |
| `Sources/iPad/ConnectionViewModel.swift` | `DrawingsUpdate` → full snapshot via `applySnapshot`, not merge |
| `AirPDFTests/AirPDFTests.swift` | 26 unit tests for `StrokeModel` |
| `AirPDF.xcodeproj/project.pbxproj` | Added `StrokeModel.swift` to project; cleaned up test target build phases |

## Deleted code

- `DocumentSession.strokeLog`, `undoIndex`, `savedUndoIndex`, `loadStrokesFromDisk`
- `OverlayCoordinator.pageStrokes`, `committedStrokes`, `applyRemoteStrokeBatch`, `applyRemoteStrokeRemove`, `applyRemoteDrawingUpdate`
- `StrokeDiffer.isEditMode`, `strokesMatch`, ordered `known` array
- `DrawingViewController.applyRemoteStrokeRemove`, `applyRemoteStrokeBatch`, `applyRemoteDrawingUpdate`
- `DocumentStore.applyDrawingsUpdate`, `decodePageStrokes`
- `TabDocument.pageStrokes`, custom `Equatable`/`Hashable`
