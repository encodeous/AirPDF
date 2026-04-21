# AirPDF — Agent Context

## Project Summary

AirPDF turns an iPad into a real-time drawing tablet for marking up PDFs hosted on a Mac. The user draws with Apple Pencil on the iPad; strokes are synced to the Mac over a local QUIC connection. The Mac is the source of truth for documents, persistence, and undo.

- **Mac app:** Native macOS (AppKit/SwiftUI). Opens/closes PDFs, hosts the QUIC server, persists strokes to disk, owns the undo stack.
- **iPad app:** Thin iPadOS client. Renders PDFs locally via PDFKit, captures Apple Pencil input via PencilKit, transmits finalized strokes to the Mac.
- **Protocol:** Protobuf over a single bidirectional QUIC stream. Schema at `/proto/airpdf.proto`.
- **Design doc:** Full spec at `/design/airpdf-design.md`.

## Repository Layout

```
/
├── design/
│   └── airpdf-design.md       # Full design document
├── proto/
│   └── airpdf.proto           # Protobuf wire protocol schema
└── AGENTS.md                  # This file
```

## Key Design Decisions

- Single bidirectional QUIC stream — strict message ordering, no OOO complexity.
- Bonjour service type: `_airpdf._udp`. User explicitly initiates connection.
- Session timeout: 1 minute of missed heartbeats → disconnect.
- One connected iPad at a time (v1).
- iPad never writes to disk. Mac owns all persistence.
- Strokes synced as finalized `PKStroke` deltas (not continuous touch points).
- Mac wins on concurrent state conflicts — iPad discards unsent deltas on `PdfData` re-send.
- Undo/redo is Mac-only; iPad forwards intent via `Undo`/`Redo` messages.
- PDF persistence: dual-layer — filled stroke outlines (visual fidelity, printable) + per-page `airpdf_drawing.pkdata` attachment (full PKDrawing round-trip). If attachment is stripped, strokes on that page are no longer editable.

## Current Status

- [x] Phase 1: Core Networking & Discovery
- [x] Phase 2: Document Transfer & Display
- [x] Phase 3: PencilKit & Drawing Sync
- [x] Phase 4: Refinement & Optimization

**Current phase:** Complete
**Last worked on:** 2026-04-21

### Phase 1 completion notes

- `NWListener` on macOS with QUIC + self-signed TLS identity (generated via `swift-certificates` each launch, stored ephemerally in keychain for `SecIdentityCreate` pairing).
- Bonjour advertisement (`_airpdf._udp`) on Mac via `listener.service`; browsing on iPad via `NWBrowser`.
- `Hello`/`Welcome` handshake with protocol version validation and single-client enforcement (rejection deferred to post-handshake to handle Happy Eyeballs multi-address probing).
- Session resume: iPad sends `resume_session_id` in `Hello`; Mac echoes it back in `Welcome`.
- Keepalive: iPad sends `Heartbeat` every 5 s; Mac silently ignores it.
- `FrameCodec`: 4-byte big-endian length-prefix framing using `startIndex`-relative slice indexing and `loadUnaligned` for safe unaligned reads.
- Protobuf code generation via SwiftProtobufPlugin build tool plugin + `proto/swift-protobuf-config.json`.
- Mac entitlements: `com.apple.security.network.server` + `com.apple.security.network.client` + read-write file access (`AirPDF/AirPDF-macOS.entitlements`).
- iPad entitlements: `com.apple.security.network.client` + `com.apple.developer.networking.bonjour.client` for `_airpdf._udp` (`AirPDF/AirPDF-iOS.entitlements`).
- `NSBonjourServices` in `Info.plist` for iPadOS Bonjour browsing permission.
- SwiftUI observation fix: nested `@Published` objects (`QuicServer.state`, `BonjourBrowser.hosts`) observed via child views with `@ObservedObject` to avoid stale renders.

### Phase 2 notes

The notes are in `/design/impl/phase2.md`.

### Phase 3 notes

The notes are in `/design/impl/phase3.md`.

Key implementation details:
- iPad uses `PDFPageOverlayViewProvider` (WWDC 2022) for per-page `PKCanvasView` overlays. PDFKit manages positioning, sizing, and recycling.
- `PKToolPicker` anchored to the `DrawingViewController` (not canvases) — survives overlay recycling.
- `StrokeDiffer` tracks stroke identity per page; handles add, remove, and lasso move (equal-count modification).
- `StrokeRemove` proto changed to `repeated string stroke_ids` (field 4) for batched removals.
- Mac display uses `PDFPageOverlayViewProvider` with `DrawingOverlayView` (`NSView` rendering `PKDrawing.image()`). Annotations only at save time.
- `ClientConnection.onMessage` dispatched to main thread — fixes silent failures from background-thread PDFKit mutations.
- Light mode forced on canvases (`overrideUserInterfaceStyle`), tool picker (`overrideUserInterfaceStyle`), and Mac overlays (`NSAppearance.aqua`).
- Known limitation: `PKCanvasView` blurry on zoom (confirmed Apple framework limitation, no workaround).

### Phase 4 notes

The notes are in `/design/impl/phase4.md`.

Key implementation details:
- Undo/redo rewritten: `strokeLog: [(id, page, stroke)]` + `undoIndex` cursor replaces `UndoManager` + `strokeMetadata` + `strokeOrder`. Active strokes = `strokeLog[0..<undoIndex]`. Each undo/redo steps exactly one stroke.
- `DrawingsUpdate` proto message (field 12): Mac → iPad, carries only `page_drawings` without PDF bytes. Sent after every undo/redo result for authoritative state sync.
- File watcher: `DispatchSourceFileSystemObject` on `O_EVTONLY` fd. Silent reload if no unsaved changes; conflict alert if `undoIndex > 0`. Watcher stopped during save to prevent self-triggering.
- Save fix: `Data.write(to:options:.atomic)` instead of `PDFDocument.write(to:)` — updates mtime correctly.
- Auto-reconnect: `QuicClient` stores `lastEndpoint`, reconnects on failure with exponential backoff (1s→2s→4s→8s→16s). `disconnectFromServer()` clears endpoint to prevent reconnect on explicit disconnect.
- iPad undo/redo: `DrawingViewController` implements `@objc undo(_:)` / `redo(_:)` on the responder chain. `PKToolPicker` built-in buttons invoke these directly. Manual Undo/Redo nav bar buttons removed.
- Remote stroke feedback: `OverlayCoordinator.applyRemoteStrokeRemove/Batch/DrawingUpdate` apply Mac undo/redo results to the live canvas without emitting deltas (delegate set to nil during update).

- v1 targets a single Mac ↔ single iPad topology.
- The same PDF cannot be opened twice simultaneously in the same Mac session.
- `document_id` is ephemeral (assigned on open, not derived from path or content).
- No password-protected or malformed PDFs — rejected cleanly.
- No PDF size limit.
- In-session PKDrawing fidelity is perfect; fidelity loss only occurs if the `airpdf_drawing.pkdata` attachment is stripped by a third-party editor.

## Test Workflow

Prefer Xcode MCP over raw shell commands for build/test feedback.

- Use `BuildProject` first to catch compile errors quickly.
- Use `XcodeRefreshCodeIssuesInFile` for focused diagnostics after touching a file.
- Use `GetTestList` to discover valid XCTest identifiers before running a subset.
- Use `RunSomeTests` for the normal fast path. It respects Xcode's active scheme, active test plan, and current destination.
- For this repo, the default verification target is `AirPDFTests` rather than `RunAllTests`.

Recommended unit-test flow:

1. `BuildProject`
2. `GetTestList`
3. `RunSomeTests` with only the relevant `AirPDFTests` identifiers
4. If the change is broad, run the full `AirPDFTests` set with `RunSomeTests`

Current useful test identifiers include:

- `StrokeModelTests/testRemoveStrokeThenUndo()`
- `StrokeModelTests/testGroupedRemoveAndAddUndoRedo()`
- `StrokeModelTests/testMacUndoRedoScenario()`

Important caveat:

- `RunAllTests` also includes `AirPDFUITests`.
- If UI test signing is not configured, macOS may show `AirPDFUITests-Runner.app is damaged and can’t be opened`.
- That dialog is from the unsigned UI test runner, not from the main AirPDF app.
- In that case, stay on `RunSomeTests` and run only the `AirPDFTests` target until UI test signing is fixed.

## Open Questions

_None currently._

## Decisions Log

| Date | Decision |
|------|----------|
| 2026-04-20 | Single bidirectional QUIC stream (simplicity over throughput) |
| 2026-04-20 | Bonjour service type: `_airpdf._udp` |
| 2026-04-20 | Dual-layer PDF persistence: filled stroke outlines + per-page PKDrawing attachment |
| 2026-04-20 | No fallback reconstruction from outlines if PKDrawing attachment is stripped |
| 2026-04-20 | Mac-wins reconciliation on concurrent edits |
| 2026-04-20 | 1-minute session timeout (covers iPad backgrounding) |
| 2026-04-20 | No PDF size limit |
| 2026-04-21 | PDFPageOverlayViewProvider for iPad canvas overlays (WWDC 2022 pattern) |
| 2026-04-21 | Tool picker anchored to VC, not canvases (survives overlay recycling) |
| 2026-04-21 | Mac display via PDFPageOverlayViewProvider + DrawingOverlayView (not annotations) |
| 2026-04-21 | StrokeRemove batched: repeated stroke_ids (field 4) |
| 2026-04-21 | Light mode forced on canvases, tool picker, and Mac overlays |
| 2026-04-21 | PKCanvasView zoom blur is confirmed Apple limitation — no workaround |
| 2026-04-21 | strokeLog + undoIndex cursor replaces UndoManager (single source of truth, O(1) undo/redo) |
| 2026-04-21 | Each undo/redo steps exactly one stroke |
| 2026-04-21 | Erase (StrokeRemove from iPad) is permanent — not undoable via strokeLog |
| 2026-04-21 | DrawingsUpdate sent alongside StrokeRemove/StrokeBatch for authoritative iPad state sync |
| 2026-04-21 | DispatchSourceFileSystemObject (O_EVTONLY) for file watching; watcher stopped during save |
| 2026-04-21 | Data.write(to:options:.atomic) for save — updates mtime; PDFDocument.write does not |
| 2026-04-21 | QuicClient auto-reconnect with exponential backoff; disconnectFromServer() prevents reconnect |
| 2026-04-21 | PKToolPicker undo/redo via @objc undo(_:)/redo(_:) on DrawingViewController responder chain |
| 2026-04-21 | Stamp annotations use `hasAppearanceStream = true` + 8× raster via `PKDrawing.image(from:scale:)` |
| 2026-04-21 | Light mode forced for annotation rendering via `performAsCurrentDrawingAppearance` |
| 2026-04-21 | `baseDrawings` on DocumentSession preserves disk-loaded strokes across strokeLog rebuilds |
| 2026-04-21 | Vector PDF via async `PKDrawing.draw(in:)` is viable but deferred — 8× raster is sufficient |
