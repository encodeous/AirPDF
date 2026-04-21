# AirPDF Phase 4 — Refinement & Optimization

## Status: Complete

## What Was Built

### 1. iPad Undo/Redo Feedback (Mac → iPad)

**`Sources/iPad/PDFCanvasView.swift`:**
- `DrawingViewController` overrides `canPerformAction(_:withSender:)` to return `true` for `undo:` / `redo:`, enabling the `PKToolPicker` built-in undo/redo buttons.
- `@objc func undo(_:)` / `redo(_:)` on `DrawingViewController` forward `Undo`/`Redo` proto messages to the Mac via `onStrokeDelta`. The VC is the first responder, so the tool picker's buttons hit these methods directly.
- `OverlayCoordinator` gains three remote-update methods:
  - `applyRemoteStrokeRemove(pageIndex:strokeIds:)` — removes strokes from `StrokeDiffer.known` by ID, rebuilds canvas drawing without emitting a delta.
  - `applyRemoteStrokeBatch(pageIndex:entries:)` — appends strokes to `StrokeDiffer.known`, rebuilds canvas drawing without emitting a delta.
  - `applyRemoteDrawingUpdate(pageIndex:drawingData:)` — replaces the full page drawing and resets the differ baseline (used for `DrawingsUpdate` messages).
- `StrokeDiffer` gains `removeStrokes(ids:)` and `addStrokes(entries:)` — mutate `known` and return the updated `PKDrawing`.
- `applyDrawingToCanvas` helper: sets `canvas.delegate = nil` before programmatic drawing update to suppress spurious delta emission, then restores the delegate.
- `DrawingViewController` exposes `applyRemoteStrokeRemove` and `applyRemoteStrokeBatch` forwarding to `overlayCoordinator`.
- `overlayCoordinator` changed from `private` to `let` (internal) so `DrawingViewController` can access `docId` for undo/redo message construction.

**`Sources/iPad/PDFCanvasView.swift` — `PDFCanvasView`:**
- Added `onVCReady: ((DrawingViewController) -> Void)?` — called in `makeUIViewController` so the parent can register the active VC for remote stroke routing.

**`Sources/iPad/PDFTabView.swift`:**
- Accepts `onVCReady: (DrawingViewController) -> Void` and passes it through to `PDFCanvasView`.

**`Sources/iPad/ConnectionView.swift`:**
- Passes `onVCReady: { [weak vm] vc in vm?.activeDrawingVC = vc }` to `PDFTabView`.
- Removed manual Undo/Redo toolbar buttons — `PKToolPicker` handles them natively.

**`Sources/iPad/ConnectionViewModel.swift`:**
- Added `weak var activeDrawingVC: DrawingViewController?`.
- `handleMessage` now handles three additional cases from Mac:
  - `.strokeRemove` → `activeDrawingVC?.applyRemoteStrokeRemove`
  - `.strokeBatch` → deserializes entries, calls `activeDrawingVC?.applyRemoteStrokeBatch`
  - `.drawingsUpdate` → `documentStore.applyDrawingsUpdate`
- Renamed `client.disconnect()` to `client.disconnectFromServer()` to resolve Swift name ambiguity with `ConnectionViewModel.disconnect()`.

**`Sources/iPad/DocumentStore.swift`:**
- Added `applyDrawingsUpdate(_ msg: Airpdf_V1_DrawingsUpdate)` — merges updated `page_drawings` into the stored `TabDocument` without replacing PDF bytes.
- Added `PencilKit` import.
- Extracted `upsert` helper.

### 2. On-Disk File Change Detection (Mac)

**`Sources/macOS/DocumentSession.swift`:**
- Added `startWatching(onChange:)` — opens the file with `O_EVTONLY` and creates a `DispatchSourceFileSystemObject` watching for `.write` events on the main queue.
- Added `stopWatching()` — cancels the source and closes the fd.
- `deinit` calls `stopWatching()`.
- Added `hasExternalConflict: Bool` flag.

**`Sources/macOS/AppModel.swift`:**
- `openPDF` calls `session.startWatching` after opening.
- Added `@Published var fileConflictSession: DocumentSession?`.
- `handleExternalFileChange(session:)` — if `undoIndex > 0` (unsaved changes), sets `fileConflictSession`; otherwise silently calls `reloadFromDisk`.
- `reloadFromDisk(session:)` — stops watcher, reloads `PDFDocument` from URL, re-reads `airpdf_drawing.pkdata` annotations, resets `strokeLog`/`undoIndex`, refreshes Mac overlays, re-sends `PdfData` to iPad, restarts watcher.
- `keepInMemory(session:)` — clears conflict state; next save overwrites the file.

**`Sources/macOS/ContentView.swift`:**
- Added `.alert("File Changed on Disk", ...)` presenting `appModel.fileConflictSession` with "Reload from Disk" (destructive) and "Keep In-Memory Version" actions.

### 3. Seamless Auto-Reconnect (iPad)

**`Sources/iPad/Networking/QuicClient.swift`:**
- Added `lastEndpoint: NWEndpoint?`, `reconnectAttempt: Int`, `reconnectTimer: DispatchSourceTimer?`.
- `connect(to:)` stores `lastEndpoint` and resets `reconnectAttempt`.
- Renamed `disconnect()` → `disconnectFromServer()` — clears `lastEndpoint` so auto-reconnect won't fire on explicit disconnect.
- `handleConnectionState(.failed)` calls `teardown(reconnect: true)`.
- `startReceiving` calls `teardown(reconnect: true)` on receive error or stream completion.
- `teardown(reconnect:)` — if `reconnect && lastEndpoint != nil`, calls `scheduleReconnect()`; otherwise sets `state = .disconnected`.
- `scheduleReconnect()` — exponential backoff: delay = `min(2^(attempt-1), 16)` seconds. Fires `makeConnection(to: lastEndpoint)` after delay.
- `handleWelcome` resets `reconnectAttempt = 0` and cancels any pending reconnect timer on successful handshake.
- Version mismatch (`unsupportedVersion`) clears `lastEndpoint` to prevent reconnect loops.
- `makeConnection(to:)` extracted as a private method (was inline in `connect`).

### 4. DrawingsUpdate Message (Proto + Mac + iPad)

**`proto/airpdf.proto`:**
- Added `DrawingsUpdate drawings_update = 12` to `Payload.oneof body`.
- Added `message DrawingsUpdate { string document_id = 1; map<uint32, bytes> page_drawings = 2; }`.

**`Sources/macOS/AppModel.swift`:**
- Added `makeDrawingsUpdate(for:)` helper — builds `DrawingsUpdate` from `session.pageDrawings`.
- Mac sends `DrawingsUpdate` after every undo/redo result (alongside `StrokeRemove`/`StrokeBatch`) to give the iPad an authoritative drawing state snapshot.

**`Sources/iPad/ConnectionViewModel.swift`:**
- Handles `.drawingsUpdate` → `documentStore.applyDrawingsUpdate`.

### 5. Undo/Redo Rewrite (Mac)

Replaced `UndoManager` + `strokeMetadata: [Int: [String: PKStroke]]` + `strokeOrder: [Int: [String]]` with a single flat log and cursor.

**`Sources/macOS/DocumentSession.swift`:**
- Removed `undoManager`, `strokeMetadata`, `strokeOrder`.
- Added `strokeLog: [(id: String, page: Int, stroke: PKStroke)]` — ordered append-only log of all received strokes.
- Added `undoIndex: Int` — cursor dividing active strokes (`[0..<undoIndex]`) from undone strokes (`[undoIndex...]`).

**`Sources/macOS/AppModel.swift`:**
- `StrokeBatch`: truncates `strokeLog[undoIndex...]` (clears redo history), appends new entries, advances `undoIndex`, calls `rebuildDrawing`.
- `StrokeRemove` (erase): permanently removes matching entries from `strokeLog`, clamps `undoIndex`, calls `rebuildDrawing`. Erases are not undoable.
- `handleUndo(session:)` — decrements `undoIndex` by 1, calls `rebuildDrawing`, sends `StrokeRemove` + `DrawingsUpdate` to iPad.
- `handleRedo(session:)` — increments `undoIndex` by 1, calls `rebuildDrawing`, sends `StrokeBatch` + `DrawingsUpdate` to iPad.
- `rebuildDrawing(session:page:)` — filters `strokeLog[0..<undoIndex]` by page, calls `updateDrawing`.
- `.undo` / `.redo` messages from iPad call `handleUndo` / `handleRedo`.

**`Sources/macOS/ContentView.swift`:**
- Undo/Redo toolbar buttons call `appModel.handleUndo(session:)` / `appModel.handleRedo(session:)`.
- Disabled state based on `s.undoIndex == 0` / `s.undoIndex >= s.strokeLog.count`.

### 6. Save Fix (Mac)

**`Sources/macOS/AppModel.swift` — `saveSelectedPDF()`:**
- Stops file watcher before write, restarts after — prevents own save from triggering a spurious conflict prompt.
- Uses `session.pdfDocument.dataRepresentation()` + `Data.write(to:options:.atomic)` instead of `PDFDocument.write(to:)`. This gives the saved file a fresh modification date (`PDFDocument.write` and `FileManager.replaceItemAt` both preserve original mtime by design).

### 7. BonjourBrowser Fix (External API Change)

**`Sources/iPad/Networking/BonjourBrowser.swift`:**
- Removed port extraction from `NWBrowser.Result.Metadata` — API changed in newer SDK, port is not needed (connection uses the `NWEndpoint` directly).
- Added explicit `-> DiscoveredHost?` return type annotation on `compactMap` closure to resolve type inference error.

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| `strokeLog` + `undoIndex` cursor | Single source of truth; no dict ordering issues; undo/redo is O(1) cursor move + O(n_page) rebuild |
| One stroke per undo/redo step | Matches user expectation; each `StrokeBatch` from iPad is one logical drawing action |
| Erase is permanent (not undoable via log) | Erases arrive as `StrokeRemove` from iPad which already applied them locally; no round-trip undo needed |
| `DrawingsUpdate` alongside `StrokeRemove`/`StrokeBatch` | Authoritative state sync — iPad canvas converges even if stroke-ID tracking diverges |
| `DispatchSourceFileSystemObject` for file watching | Lightweight, no polling; fires on `.write` events; `O_EVTONLY` doesn't prevent deletion |
| Stop watcher during save | Prevents own write from triggering conflict prompt |
| `Data.write(to:options:.atomic)` for save | Updates mtime; `PDFDocument.write` and `replaceItemAt` preserve original mtime |
| `disconnectFromServer()` rename | Avoids Swift ambiguity between `ConnectionViewModel.disconnect()` and `QuicClient.disconnect()` |
| `PKToolPicker` undo/redo via responder chain | Native UX; `@objc undo(_:)` / `redo(_:)` on first-responder VC intercepts tool picker button taps |

### 8. PDF Save Annotations (Mac)

**`Sources/macOS/StrokeAnnotation.swift` — `DrawingAnnotation`:**
- Stamp annotation with `hasAppearanceStream = true` so PDFKit generates the `/AP` stream on serialization.
- Renders `PKDrawing.image(from:scale: 8.0)` at init time (high-res raster). Scale 8× produces sharp output for print and zoom.
- Forces light mode via `NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {}` — prevents dark mode from inverting black ink to white.
- Pre-renders at init, not in `draw(with:in:)` — avoids re-rendering on every appearance stream request.

**`Sources/macOS/AppModel.swift` — `saveSelectedPDF()`:**
- Removes old Stamp and FileAttachment annotations before adding new ones (prevents duplication on re-save).
- Adds hidden `airpdf_drawing.pkdata` FileAttachment per page (round-trip fidelity).
- Adds visible `DrawingAnnotation` stamp per page (printable, visible in any PDF viewer).

**`Sources/macOS/DocumentSession.swift`:**
- Added `baseDrawings: [Int: PKDrawing]` — caches drawings loaded from disk at init/reload time.
- `rebuildDrawing` merges `baseDrawings[page].strokes` + session `strokeLog` strokes, so pre-existing drawings are preserved when new strokes arrive.

**Vector rendering investigation:**
- `PKDrawing.draw(in:CGContext:frame:from:darkUserInterfaceStyle:)` is async and renders vector output into any CGContext. However, the annotation `draw(with:in:)` callback is synchronous and the CGContext is only valid during that call — cannot bridge with semaphore (priority inversion + invalid context).
- Attempted pre-rendering into a PDF-backed CGContext at save time (async), wrapping result as `NSPDFImageRep` — this works but adds complexity (save becomes async).
- Decision: 8× raster is sufficient quality for the use case. Vector via async pre-render is a known viable path if needed later.

## Known Limitations

- **Erase is not undoable**: `StrokeRemove` from iPad (erase) permanently removes from `strokeLog`. A future version could push erase operations onto the log as tombstones.
- **Multi-page undo ordering**: `strokeLog` is global across pages; undo steps through strokes in arrival order regardless of which page they're on. This is correct but may feel surprising if the user switches pages between strokes.
- **Mac overlay is raster**: `DrawingOverlayView` still uses `PKDrawing.image()`. Vector rendering deferred.
- **Stamp annotations are high-res raster (8×), not vector**: PencilKit lacks a synchronous vector rendering API. The async `PKDrawing.draw(in:)` path works but requires making save async. 8× scale is sharp enough for print.

## Files Created

_None._

## Files Modified

| File | Change |
|------|--------|
| `proto/airpdf.proto` | Added `DrawingsUpdate` message (field 12) |
| `Sources/macOS/DocumentSession.swift` | Replaced strokeMetadata/strokeOrder/undoManager with strokeLog+undoIndex; added file watcher |
| `Sources/macOS/AppModel.swift` | strokeLog cursor undo/redo; handleUndo/handleRedo; file conflict handling; save fix |
| `Sources/macOS/ContentView.swift` | Undo/Redo buttons use handleUndo/handleRedo; file conflict alert |
| `Sources/iPad/PDFCanvasView.swift` | undo:/redo: responder methods; applyRemote* on OverlayCoordinator; StrokeDiffer removeStrokes/addStrokes; onVCReady |
| `Sources/iPad/PDFTabView.swift` | Passes onVCReady through |
| `Sources/iPad/ConnectionView.swift` | Passes onVCReady; removed manual Undo/Redo buttons |
| `Sources/iPad/ConnectionViewModel.swift` | Handles strokeRemove/strokeBatch/drawingsUpdate from Mac; activeDrawingVC; disconnectFromServer |
| `Sources/iPad/DocumentStore.swift` | applyDrawingsUpdate; upsert helper; PencilKit import |
| `Sources/iPad/Networking/QuicClient.swift` | Auto-reconnect with exponential backoff; disconnectFromServer rename |
| `Sources/iPad/Networking/BonjourBrowser.swift` | Fixed NWBrowser.Result.Metadata API change |
