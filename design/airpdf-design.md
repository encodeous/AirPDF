# AirPDF Design Document

## Background & Motivation
AirPDF aims to turn the iPad into a real-time, low-latency drawing tablet for marking up PDFs that are hosted on a Mac. This application allows users to leverage the superior Apple Pencil drawing experience natively on an iPad without transferring source files between devices. The core focus is absolute minimal latency, high-performance rendering (leveraging Metal and native frameworks), and robust device communication over local networks.

## Scope & Impact
*   **macOS Application:** Acts as the source of truth for document management. Opens, edits (text boxes, new pages, etc.), and closes PDF documents. Hosts the QUIC server and pushes document state to the iPad. Receives and persists stroke data from the iPad.
*   **iPadOS Application:** Acts as a thin, pencil-input-only client. Renders PDFs locally for maximum responsiveness, presents each open document as a tab, and transmits only Apple Pencil stroke data back to the Mac. Navigation (page, scroll, zoom) is independent per device and is never synchronized.
*   **Multi-Document Tab View:** Both Mac and iPad support multiple documents open simultaneously. The Mac drives which documents the iPad has loaded (open/close), but each device navigates its own tabs independently.
*   **Network Synchronization:** Implementation of Apple's Network framework using the QUIC protocol to ensure low-latency data transmission with built-in reliability and security.
*   **Data Serialization:** Efficient diffing and synchronization of `PKStroke` data.
*   **Extensibility:** Forward-compatible data structures that can support annotations, text boxes, and layers in future iterations.

## Proposed Solution

### 1. Network Architecture: QUIC (NWProtocolQUIC)
We will utilize Apple's `Network` framework configured for the QUIC protocol. QUIC provides the perfect balance between the ultra-low latency of UDP and the reliability of TCP, avoiding head-of-line blocking while maintaining connection security and data integrity.
*   **Mac (Host):** Runs an `NWListener` broadcasting the service or listening on a specific port.
*   **iPad (Client):** Connects to the Mac's IP address manually via an `NWConnection`.
*   **Messaging Protocol:** A protobuf-based framing protocol over QUIC streams to differentiate between command messages (e.g., "Load PDF", "Close Document") and data payloads (e.g., "New Stroke Data"). Message schema is defined in `/proto/airpdf.proto`.
*   **Handshake:** On every new connection the iPad sends `Hello` (carrying `protocol_version` and `app_version`). The Mac validates the version and replies with `Welcome` (carrying a `session_id`). Immediately after `Welcome` the Mac re-sends `PdfData` for every currently-open document so the iPad can restore full session state. If the iPad reconnects and receives a different `session_id` in `Welcome`, it discards all cached document state before processing the new `PdfData` stream. Incompatible protocol versions are rejected with `ERROR_CODE_UNSUPPORTED_VERSION` followed by connection teardown.

### 2. PDF Rendering Strategy: iPad Local Rendering
To minimize bandwidth after the initial connection and provide the smoothest zooming/panning experience on the iPad:
*   When the Mac opens a document, it **strips all ink annotations** from the PDF before transmitting it as `PdfData.content`. Stripping is essential: without it, PDFKit on the iPad would render the saved ink paths from the PDF layer *and* the `PKCanvasView` overlay would render the same strokes — double-drawing the ink. Alongside the stripped PDF, `PdfData` carries a `page_drawings` map (page index → `PKDrawing.dataRepresentation()`) so the iPad can populate each per-page `PKCanvasView` overlay immediately, without any additional round-trip. When the Mac re-sends `PdfData` with the same `document_id` (e.g., after adding text boxes or new pages), it follows the same strip-then-send flow and includes an up-to-date `page_drawings` snapshot.
*   The iPad stores each received PDF ephemerally (in memory or a temporary cache) and renders it natively using `PDFKit` (which is backed by Metal). Each document appears as a separate tab.
*   When the Mac closes a document, it sends `PdfClose`; the iPad removes the corresponding tab and frees all associated `PKDrawing` state.
*   **Per-page canvas architecture:** A dedicated `PKCanvasView` is created for each PDF page and positioned precisely over that page's frame within the `PDFView` layout (using `PDFView.convert(_:from:page:)` for coordinate mapping). All per-page canvases scroll and zoom in lockstep with the `PDFView`. Each canvas holds only the `PKDrawing` for its page, loaded from `PdfData.page_drawings` on open. This one-canvas-per-page model keeps coordinate spaces clean and makes per-page `PKDrawing` persistence straightforward.
*   Page navigation, scroll position, and zoom level are **not** synchronized — each device scrolls and navigates independently.

### 3. Stroke Persistence: Editable Handwriting inside the PDF
AirPDF must be able to save a marked-up PDF, close it, reopen it, and continue editing the handwriting — without flattening the strokes into pixels.

#### How other apps approach this
| App | Editable after save? | Mechanism |
|---|---|---|
| Apple Preview / Markup | ✅ | Standard PDF `/Ink` annotations (ISO 32000 §12.5.6.13) |
| PDF Expert / Acrobat | ✅ | Same standard PDF `/Ink` annotations |
| GoodNotes 5/6 | ❌ in PDF export | Proprietary `.goodnotes` zip; PDF export flattens to raster |
| Notability | ❌ in PDF export | Proprietary `.note` format; PDF export flattens |
| Xournal++ | ✅ in `.xopp` only | XML container; PDF export flattens |

#### Chosen approach: dual-layer storage inside the PDF
AirPDF uses a **dual-layer strategy** — everything lives inside the `.pdf` file itself; no sidecar files are needed.

**Layer 1 — Visual (standard PDF ink annotation):**
Each page that has strokes gets exactly one `PDFAnnotation` of subtype `.ink` (using `PDFKit`'s `PDFAnnotationSubtype.ink`). The annotation stores simplified polyline paths (`inkList`) derived from the `PKDrawing` for that page. Any PDF viewer (Preview, Acrobat, PDF Expert, iOS Files) can render these paths without knowing anything about AirPDF.

**Layer 2 — Data (custom annotation key `AirPDFStrokeData`):**
The same annotation carries a custom dictionary key `/AirPDFStrokeData`. Its value is the Base64-encoded binary output of `PKDrawing.dataRepresentation()` for that page. `PDFAnnotation` exposes `setValue(_:forAnnotationKey:)`, which writes arbitrary entries into the annotation's PDF dictionary; conforming PDF viewers that do not understand the key silently ignore it. When AirPDF reopens the file it reads this key and calls `PKDrawing(data:)`, restoring full PencilKit fidelity — pressure, tilt, velocity, tool type, and color all survive the round-trip.

This is the same strategy used by OneNote (rich private data embedded alongside a standards-compliant rendering), expressed entirely within standard PDF annotation dictionary entries.

#### Persistence lifecycle (Mac only — iPad never writes to disk)
*   **On open:** for each `.ink` annotation on a page, attempt to read `/AirPDFStrokeData` → `PKDrawing(data:)` → cache as the per-page drawing. If the key is absent (file annotated by a third-party app), fall back to constructing a `PKDrawing` from the standard ink paths (lower fidelity, but still editable).
*   **Before sending to iPad:** strip all `.ink` annotations (including the `/AirPDFStrokeData` key) from the PDF bytes to produce an ink-free `PdfData.content`. Populate `PdfData.page_drawings` from the same per-page `PKDrawing` cache. This ensures the iPad's `PKCanvasView` overlay is the only source of stroke rendering.
*   **On save:** for each page, serialize its `PKDrawing` → Base64 → set `/AirPDFStrokeData` on the page's `.ink` annotation; update the annotation's `inkList` paths for visual compatibility; call `PDFDocument.write(to:)`.
*   **Stroke updates from iPad** are merged into the in-memory `PKDrawing` and flushed to disk on the next explicit save.

### 4. Drawing Synchronization: Finalized Strokes
To optimize network traffic and simplify conflict resolution, the synchronization will operate at the finalized stroke level.
*   **Capture:** The iPad app listens to `PKCanvasViewDelegate`'s `canvasViewDrawingDidChange(_:)`.
*   **Diffing:** Each page canvas maintains a cache of the previously-known set of `stroke_id`s. Upon a change, it identifies the delta (new strokes → `StrokeBatch`; removed strokes → `StrokeRemove`).
*   **Transmission:** Only the delta is sent to the Mac. `StrokeBatch` groups all new strokes for the same page into a single message to reduce framing overhead during fast writing. Because `PKStroke` has no public standalone serializer, each `StrokeEntry.pk_stroke_data` is `PKDrawing.dataRepresentation()` of a single-stroke `PKDrawing` wrapper (`PKDrawing(strokes: [stroke]).dataRepresentation()`), and the UUID `stroke_id` is assigned by the iPad for deduplication and removal tracking.
*   **Reconstruction:** The Mac receives the delta, deserializes each `StrokeEntry`, and merges the stroke into its in-memory `PKDrawing` for the correct document and page, updating its display synchronously.
*   **Undo/Redo:** The Mac is the **sole source of truth** for the undo/redo stack — it covers all actions in chronological order (stroke batches received from the iPad and document edits made on the Mac). The iPad never manages its own undo state independently; its undo/redo button (pencil double-tap, keyboard shortcut, or on-screen control) simply forwards an `Undo`/`Redo` message to the Mac. The Mac applies the action and pushes the result back:
    *   If the undone/redone action was a **stroke**, the Mac updates its in-memory `PKDrawing` and sends `StrokeRemove` (undo) or `StrokeBatch` (redo) to the iPad so the canvas reflects the new state.
    *   If the undone/redone action was **non-stroke** (e.g. a text box or page insertion), the Mac applies the change to the document and re-sends `PdfData` with updated content and a current `page_drawings` snapshot.
    The iPad's undo/redo button availability (enabled/disabled) mirrors the Mac's undo stack state; the Mac can send a future `UndoState` message to keep the button in sync (reserved for a later iteration).

### Data Structures & Extensibility
All messages are framed as a `SyncEnvelope` protobuf message (timestamp + `Payload` oneof). The `Payload` oneof covers: `Hello`, `Welcome`, `Ping`, `Pong`, `PdfData`, `StrokeBatch`, `StrokeRemove`, `PdfClose`, `Undo`, `Redo`, and `Error`. See `/proto/airpdf.proto` for the canonical schema. This structure ensures that future features (like `.textAnnotation` or `.layerState`) can be added as new oneof variants without rewriting the networking layer.

## Alternatives Considered
*   **Custom UDP Networking:** Rejected in favor of QUIC. While UDP offers the absolute lowest theoretical latency, it requires a massive development effort to manually implement packet ordering, retransmissions for critical data (like stroke data), and security. QUIC provides these automatically with negligible latency overhead.
*   **Mac Remote Rendering (Image Streaming):** Rejected. Having the Mac stream rendered frames to the iPad creates a "truer" thin client but significantly degrades the iPad's zooming and panning performance. It also requires substantially more continuous bandwidth, making it susceptible to network jitters.
*   **Real-time Continuous Stroke Streaming:** Rejected for initial scope. Streaming continuous touch points over the network introduces significant complexity in managing the "in-progress" stroke state versus the finalized `PKStroke`. Finalized strokes provide a stable, highly reliable initial implementation.

## Implementation Plan
### Phase 1: Core Networking & Discovery
1.  Implement `NWListener` on macOS.
2.  Implement `NWConnection` on iPadOS with a manual IP entry UI.
3.  Establish a basic QUIC connection and verify bi-directional ping/pong latency.
4.  Implement `Hello`/`Welcome` handshake with protocol version validation; implement reconnection logic (discard cached state on new `session_id`).

### Phase 2: Document Transfer & Display
1.  Implement the `SyncEnvelope` framing and protobuf codec.
2.  Mac: Build tab-based UI to open one or more PDFs; strip ink annotations from the PDF bytes, populate `page_drawings` from the in-memory `PKDrawing` cache, and transmit as `PdfData`; send `PdfClose` when a tab is closed.
3.  iPad: Receive `PdfData` payloads; display each document in its own tab using `PDFView` (PDFKit); replace the cached PDF silently on re-send; close the tab on `PdfClose`; pre-allocate per-page `PKDrawing` cache from `page_drawings`.

### Phase 3: PencilKit & Drawing Sync
1.  iPad: Create one `PKCanvasView` per PDF page, sized and positioned over each page's frame in the `PDFView` layout; keep all canvases in sync with `PDFView` scroll and zoom via `PDFViewDelegate`.
2.  iPad: On `PdfData` receipt, load each page's `PKDrawing` from `page_drawings` into the corresponding canvas (empty drawing for pages absent from the map).
3.  iPad: Implement per-page stroke diffing in `canvasViewDrawingDidChange`; maintain a `stroke_id`→`PKStroke` cache per page.
4.  iPad: Serialize stroke deltas as `StrokeBatch` (additions) and `StrokeRemove` (deletions/erases/undos) and transmit to Mac.
5.  Mac: Receive `StrokeBatch`/`StrokeRemove`, merge into the in-memory per-page `PKDrawing`, and render on the Mac's corresponding PDF view.
6.  Mac: On document open, read `/AirPDFStrokeData` custom key from each page's `.ink` annotation and hydrate the per-page `PKDrawing`; fall back to standard ink paths if the key is absent.
7.  Mac: Before sending `PdfData`, strip all ink annotations from the PDF bytes and populate `page_drawings`; on document save, serialize each page's `PKDrawing` into `/AirPDFStrokeData` and update the `inkList` visual paths, then write the PDF.
8.  Mac: Maintain the global document-level undo stack (covering both Mac document edits and iPad stroke batches in arrival order). Implement `Undo`/`Redo` toolbar buttons on the Mac. On receiving `Undo`/`Redo` from the iPad (or triggering it locally), apply the action: if stroke-related, push `StrokeRemove`/`StrokeBatch` to the iPad; if non-stroke, re-send `PdfData` with the updated document. The iPad never independently invokes its `PKCanvasView` `UndoManager` for undo/redo.

### Phase 4: Refinement & Optimization
1.  Profile latency using Instruments and optimize data serialization.
2.  Add error handling for network drops and seamless reconnection.
3.  Handle large PDF updates efficiently (e.g., delta or incremental re-send if the Mac PDF changes frequently).

## Verification & Testing
*   **Latency Testing:** Measure the millisecond delta between stroke completion on the iPad and appearance on the Mac. Target: < 50ms on local Wi-Fi.
*   **Network Resiliency:** Use Network Link Conditioner to simulate high packet loss and high latency. Verify that QUIC correctly recovers without dropping strokes or deadlocking.
*   **Memory Profiling:** Ensure the iPad does not leak memory when repeatedly opening and closing large PDFs.
*   **Fidelity:** Verify that stroke thickness, color, and opacity render identically on both macOS and iPadOS.
*   **Persistence Round-trip:** Save a marked-up PDF, reopen it in AirPDF, and verify that all strokes are fully editable (pressure, tool type, etc. preserved). Also open the saved file in Apple Preview and PDF Expert to confirm the standard ink annotation visual layer renders correctly.

## Migration & Rollback
*   As this is a greenfield application, there is no legacy data to migrate.
