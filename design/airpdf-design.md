# AirPDF Design Document

## Background & Motivation
AirPDF aims to turn the iPad into a real-time, low-latency drawing tablet for marking up PDFs that are hosted on a Mac. This application allows users to leverage the superior Apple Pencil drawing experience natively on an iPad without transferring source files between devices. The core focus is absolute minimal latency, high-performance rendering (leveraging Metal and native frameworks), and robust device communication over local networks.

## Scope & Impact
*   **macOS Application:** Acts as the source of truth for document management. Opens, edits (text boxes, new pages, etc.), and closes PDF documents. Hosts the QUIC server and pushes document state to the iPad. Receives and persists stroke data from the iPad.
*   **iPadOS Application:** Acts as a thin, pencil-input-only client. Renders PDFs locally for maximum responsiveness, presents each open document as a tab, and transmits only Apple Pencil stroke data back to the Mac. Navigation (page, scroll, zoom) is independent per device and is never synchronized.
*   **Multi-Document Tab View:** Both Mac and iPad support multiple documents open simultaneously. The Mac drives which documents the iPad has loaded (open/close), but each device navigates its own tabs independently.
*   **Single Active Client:** v1 supports exactly one connected iPad at a time. If a second iPad attempts to connect while a client is already attached, the connection is rejected.
*   **Document Instances:** `document_id` is ephemeral and assigned when a file is opened. v1 can avoid ambiguous duplicate instances by not allowing the same source PDF to be opened twice simultaneously in the same app session.
*   **Network Synchronization:** Implementation of Apple's Network framework using the QUIC protocol to ensure low-latency data transmission with built-in reliability and security.
*   **Data Serialization:** Efficient diffing and synchronization of `PKStroke` data.
*   **Extensibility:** Forward-compatible data structures that can support annotations, text boxes, and layers in future iterations.

## Proposed Solution

### 1. Network Architecture: QUIC (NWProtocolQUIC)
We will utilize Apple's `Network` framework configured for the QUIC protocol. QUIC provides the perfect balance between the ultra-low latency of UDP and the reliability of TCP, avoiding head-of-line blocking while maintaining connection security and data integrity.
*   **Mac (Host):** Runs an `NWListener`, listens on a specific port, and advertises itself over Bonjour using service type `_airpdf._udp` (QUIC runs over UDP).
*   **iPad (Client):** Uses Bonjour to discover/fill in available hosts, but the user still explicitly initiates the connection via an `NWConnection`.
*   **Stream Strategy:** A single bidirectional QUIC stream carries all messages for the lifetime of the connection. This guarantees strict message ordering (no out-of-order delivery between control messages and data payloads) at the cost of head-of-line blocking during large `PdfData` transfers. For v1 this tradeoff is acceptable — simplicity and correctness over throughput optimization.
*   **Messaging Protocol:** A protobuf-based framing protocol over the single QUIC stream to differentiate between command messages (e.g., "Load PDF", "Close Document") and data payloads (e.g., "New Stroke Data"). Message schema is defined in `/proto/airpdf.proto`.
*   **Handshake:** On every new connection the iPad sends `Hello` (carrying `protocol_version` and `app_version`). The Mac validates the version and replies with `Welcome` (carrying a `session_id`). Immediately after `Welcome` the Mac re-sends `PdfData` for every currently-open document so the iPad can restore full session state. Incompatible protocol versions are rejected with `ERROR_CODE_UNSUPPORTED_VERSION` followed by connection teardown.
*   **Session Lifetime:** A `session_id` is created when the user explicitly initiates a connection. Automatic reconnects reuse that `session_id` as long as the session is re-established within a 1-minute timeout window. QUIC transport-level keepalive is used to detect liveness (configured via `keepaliveIdle`/`keepaliveInterval` on `NWProtocolQUIC.Options`). If the QUIC connection drops and is not re-established within 1 minute, the next connection attempt is treated as a new session and the iPad discards all cached document state before processing the fresh `PdfData` stream.
*   **iPad Backgrounding:** When the iPad app is backgrounded, iOS will suspend it and the QUIC connection will go silent. QUIC keepalive probes will eventually fail, and the Mac tears down the connection. When the iPad returns to the foreground, it detects the dead connection and initiates a reconnect. If within the 1-minute window, the existing `session_id` is reused; otherwise a fresh session begins.
*   **Security:** v1 relies on QUIC's built-in encryption only. There is no pairing or access-control flow yet, though the app may expose a connection fingerprint and transport stats on a non-blocking debug/info page.

### 2. PDF Rendering Strategy: iPad Local Rendering
To minimize bandwidth after the initial connection and provide the smoothest zooming/panning experience on the iPad:
*   When the Mac opens a document, it reconstructs a per-page `PKDrawing` cache from the PDF's stroke outline annotations, then **strips all stroke annotations** from the transmitted `PdfData.content`. Stripping is essential: without it, PDFKit on the iPad would render the saved outline paths from the PDF layer *and* the `PKCanvasView` overlay would render the same strokes — double-drawing the ink. Alongside the stripped PDF, `PdfData` carries a `page_drawings` map (page index → `PKDrawing.dataRepresentation()`) so the iPad can populate each per-page `PKCanvasView` overlay immediately, without any additional round-trip. When the Mac re-sends `PdfData` with the same `document_id` (e.g., after adding text boxes or new pages), it follows the same strip-then-send flow and includes an up-to-date `page_drawings` snapshot.
*   The iPad stores each received PDF ephemerally (in memory or a temporary cache) and renders it natively using `PDFKit` (which is backed by Metal). Each document appears as a separate tab.
*   When the Mac closes a document, it sends `PdfClose`; the iPad removes the corresponding tab and frees all associated `PKDrawing` state.
*   **Per-page canvas architecture:** A dedicated `PKCanvasView` is created for each PDF page and positioned precisely over that page's frame within the `PDFView` layout (using `PDFView.convert(_:from:page:)` for coordinate mapping). All per-page canvases scroll and zoom in lockstep with the `PDFView`. Each canvas holds only the `PKDrawing` for its page, loaded from `PdfData.page_drawings` on open. For v1, canvases remain attached for all pages in the open document instead of being virtualized or recycled during zoom/scroll. This one-canvas-per-page model keeps coordinate spaces clean and makes per-page `PKDrawing` persistence straightforward.
*   Page navigation, scroll position, and zoom level are **not** synchronized — each device scrolls and navigates independently.
*   **Mac-Driven Structural Changes:** If the Mac changes page structure or geometry while the iPad is connected, the Mac re-sends `PdfData` and the iPad replaces its local state (see Reconciliation in §4). If the page count changes (pages added or removed), the iPad tears down all existing `PKCanvasView` instances for that document and recreates them from the new `PdfData.page_drawings` map. If the user is viewing a page that no longer exists, the iPad navigates to the nearest valid page.

### 3. Stroke Persistence: Editable Handwriting inside the PDF
AirPDF must be able to save a marked-up PDF, close it, reopen it, and continue editing the handwriting without flattening the strokes into pixels. AirPDF converts each `PKStroke` into a filled outline path that preserves the visual appearance of pressure-varying strokes, ensuring the saved PDF looks identical to what was drawn — including when printed.

**In-session fidelity:** While a document is open, the in-memory `PKDrawing` on both Mac and iPad retains full PencilKit fidelity — pressure curves, tilt, velocity, tool type, and all other `PKStroke` metadata are preserved exactly as drawn. What the user sees on the `PKCanvasView` is pixel-accurate to what they drew.

**Visual fidelity on save (stroke outline conversion):** To ensure the saved PDF looks identical to what was drawn — including when printed or viewed in any PDF reader — AirPDF converts each `PKStroke` into a **filled outline path** rather than a uniform-width polyline. The conversion works as follows:
1.  Walk the `PKStrokePath` control points, sampling at sufficient density along the parametric path.
2.  At each sample point, read the point's `size` property (which encodes the pressure/tilt-derived width) and compute perpendicular offsets from the stroke centerline.
3.  Build two parallel edge paths (left side and right side of the stroke envelope).
4.  Close the two edges into a single filled `UIBezierPath` representing the stroke's visual outline.
5.  Store this filled shape as a PDF annotation (ink annotation with the outline path, or a stamp/free-form annotation with a filled appearance stream).

This produces a PDF where every stroke visually matches the `PKCanvasView` rendering — variable width, tapered ends, and all — in any compliant PDF viewer and when printed.

**Perfect recovery via embedded PKDrawing data:** Alongside the filled outline annotations, AirPDF embeds the raw `PKDrawing.dataRepresentation()` bytes **per page** as a page-level embedded file annotation (a file attachment annotation named `airpdf_drawing.pkdata` on each page). This keeps the PKDrawing data co-located with its page — if pages are inserted, deleted, or reordered (in AirPDF or another editor), each page's recovery data travels with it. On reopen:
1.  If the page's embedded `airpdf_drawing.pkdata` attachment is present, AirPDF restores the exact `PKDrawing` for that page — perfect round-trip with zero fidelity loss.
2.  If the attachment is missing (e.g., stripped by a third-party editor), that page is treated as having no editable strokes in AirPDF. The filled outlines remain visible in the PDF but are not loaded into `PKCanvasView` for editing.

This dual-layer approach gives **perfect print fidelity** (filled outlines in the PDF layer) and **perfect editing recovery** (embedded PKDrawing data) simultaneously.

#### How other apps approach this
| App | Editable after save? | Mechanism |
|---|---|---|
| Apple Preview / Markup | ✅ | Standard PDF `/Ink` annotations (ISO 32000 §12.5.6.13) |
| PDF Expert / Acrobat | ✅ | Same standard PDF `/Ink` annotations |
| GoodNotes 5/6 | ❌ in PDF export | Proprietary `.goodnotes` zip; PDF export flattens to raster |
| Notability | ❌ in PDF export | Proprietary `.note` format; PDF export flattens |
| Xournal++ | ✅ in `.xopp` only | XML container; PDF export flattens |

#### Chosen approach: filled stroke outlines + embedded PKDrawing data
AirPDF uses a **dual-layer strategy** — the PDF contains both a visually accurate representation (filled outline annotations) and a lossless recovery source (embedded `PKDrawing` data).

1.  **Visual layer (filled outlines):** Each `PKStroke` is converted to a closed, filled path representing its variable-width envelope and stored as a PDF annotation. Any PDF viewer renders these correctly, and printed output matches the on-screen drawing exactly.
2.  **Recovery layer (per-page embedded file):** Each page carries a file attachment annotation (`airpdf_drawing.pkdata`) containing the raw `PKDrawing.dataRepresentation()` for that page. This preserves all PencilKit metadata for perfect round-trip editing in AirPDF, and survives page deletion/reordering since the data travels with its page.

Any PDF viewer (Preview, Acrobat, PDF Expert, iOS Files) renders the filled outlines without knowing anything about AirPDF. If a page's `airpdf_drawing.pkdata` attachment is ever stripped by a third-party editor, the outlines remain visible in the PDF but that page's strokes are no longer editable in AirPDF.

#### Persistence lifecycle (Mac only — iPad never writes to disk)
*   **On open:** for each page, check for an `airpdf_drawing.pkdata` file attachment annotation. If present, deserialize the `PKDrawing` directly (full fidelity). If absent, that page has no editable strokes — the filled outlines remain in the PDF layer but are not loaded into `PKCanvasView`.
*   **Before sending to iPad:** strip all stroke outline annotations and `airpdf_drawing.pkdata` attachments from the PDF bytes to produce `PdfData.content`. Populate `PdfData.page_drawings` from the per-page `PKDrawing` cache. This ensures the iPad's `PKCanvasView` overlay is the only source of ink rendering.
*   **On save:** for each page, convert the current `PKDrawing`'s strokes into filled outline paths and store them as PDF annotations. Additionally, attach the page's `PKDrawing.dataRepresentation()` as a file attachment annotation (`airpdf_drawing.pkdata`) on that page. Call `PDFDocument.write(to:)`. Non-stroke annotations are preserved untouched.
*   **Stroke updates from iPad** are merged into the in-memory `PKDrawing` and flushed to disk on the next explicit save.
*   **Invalid Input PDFs:** v1 rejects password-protected, malformed, or otherwise unsupported PDFs cleanly instead of attempting partial recovery.
*   **PDF Size:** There is no imposed size limit on input PDFs. Large files may result in longer initial transfer times over the single QUIC stream, but this is acceptable for v1.

### 4. Drawing Synchronization: Finalized Strokes
To optimize network traffic and simplify conflict resolution, the synchronization will operate at the finalized stroke level.
*   **Capture:** The iPad app listens to `PKCanvasViewDelegate`'s `canvasViewDrawingDidChange(_:)`.
*   **Diffing:** Each page canvas maintains a cache of the previously-known set of `stroke_id`s. Upon a change, it identifies the delta (new strokes → `StrokeBatch`; removed strokes → `StrokeRemove`).
*   **Transmission:** Only the delta is sent to the Mac. `StrokeBatch` groups all new strokes for the same page into a single message to reduce framing overhead during fast writing. Because `PKStroke` has no public standalone serializer, each `StrokeEntry.pk_stroke_data` is `PKDrawing.dataRepresentation()` of a single-stroke `PKDrawing` wrapper (`PKDrawing(strokes: [stroke]).dataRepresentation()`), and the UUID `stroke_id` is assigned by the iPad for deduplication and removal tracking. Finalized strokes are preserved 1:1 without additional coalescing or compression in v1.
*   **Reconstruction:** The Mac receives the delta, deserializes each `StrokeEntry`, and merges the stroke into its in-memory `PKDrawing` for the correct document and page, updating its display synchronously. `stroke_id` bookkeeping lives in a parallel per-page in-memory metadata map rather than inside the persisted PDF format.
*   **Eraser Semantics:** If PencilKit splits a stroke due to partial erasure, the resulting fragments are treated as new strokes with new `stroke_id`s, and the replaced source stroke is removed.
*   **Reconciliation:** The iPad always sends stroke deltas optimistically. The Mac is the sole reconciler — it merges incoming deltas into its in-memory `PKDrawing` on a best-effort basis. If the Mac re-sends `PdfData` for the same `document_id` (e.g., after a text box edit or page insertion), the incoming `PdfData` fully replaces the iPad's local PDF bytes, per-page drawings, and stroke identity maps. Any unsent local deltas for that document are discarded. In practice this race is rare — it only occurs when the Mac and iPad both make changes at the exact same moment — so the simple "Mac wins" replacement is acceptable for v1.
*   **Stroke Identity After State Replacement:** When the iPad loads a new `PKDrawing` from an incoming `PdfData.page_drawings`, it treats the loaded drawing as the new baseline. The per-page `stroke_id` cache is rebuilt by assigning fresh UUIDs to each stroke in the replacement drawing (indexed by position). No deltas are emitted for this replacement — the next `canvasViewDrawingDidChange` diff runs against this new baseline.
*   **Undo/Redo:** The Mac is the **sole source of truth** for the undo/redo stack — it covers all actions in chronological order by arrival time (stroke batches received from the iPad and document edits made on the Mac). The iPad never manages its own undo state independently; its undo/redo button (pencil double-tap, keyboard shortcut, or on-screen control) simply forwards an `Undo`/`Redo` message to the Mac. The Mac applies the action and pushes the result back:
    *   If the undone/redone action was a **stroke**, the Mac updates its in-memory `PKDrawing` and sends `StrokeRemove` (undo) or `StrokeBatch` (redo) to the iPad so the canvas reflects the new state.
    *   If the undone/redone action was **non-stroke** (e.g. a text box or page insertion), the Mac applies the change to the document and re-sends `PdfData` with updated content and a current `page_drawings` snapshot.
    The iPad's undo/redo button availability (enabled/disabled) mirrors the Mac's undo stack state; the Mac can send a future `UndoState` message to keep the button in sync (reserved for a later iteration).

### Data Structures & Extensibility
All messages are framed as a `SyncEnvelope` protobuf message (timestamp + `Payload` oneof). The `Payload` oneof covers: `Hello`, `Welcome`, `PdfData`, `StrokeBatch`, `StrokeRemove`, `PdfClose`, `Undo`, `Redo`, and `Error`. Liveness is handled by QUIC transport-level keepalive — no application-level `Ping`/`Pong` messages are needed.

## Alternatives Considered
*   **Custom UDP Networking:** Rejected in favor of QUIC. While UDP offers the absolute lowest theoretical latency, it requires a massive development effort to manually implement packet ordering, retransmissions for critical data (like stroke data), and security. QUIC provides these automatically with negligible latency overhead.
*   **Mac Remote Rendering (Image Streaming):** Rejected. Having the Mac stream rendered frames to the iPad creates a "truer" thin client but significantly degrades the iPad's zooming and panning performance. It also requires substantially more continuous bandwidth, making it susceptible to network jitters.
*   **Real-time Continuous Stroke Streaming:** Rejected for initial scope. Streaming continuous touch points over the network introduces significant complexity in managing the "in-progress" stroke state versus the finalized `PKStroke`. Finalized strokes provide a stable, highly reliable initial implementation.

## Implementation Plan
### Phase 1: Core Networking & Discovery
1.  Implement `NWListener` on macOS.
2.  Implement Bonjour advertisement on macOS and Bonjour browsing on iPadOS to prefill discoverable hosts.
3.  Implement `NWConnection` on iPadOS with explicit user-initiated connect UI.
4.  Establish a basic QUIC connection and verify bi-directional ping/pong latency.
5.  Implement `Hello`/`Welcome` handshake with strict protocol version validation, single-client rejection, and reconnect logic that reuses `session_id` for up to 1 minute. Configure QUIC transport-level keepalive (`keepaliveIdle` = 10 s, `keepaliveInterval` = 10 s) for liveness detection instead of application-level ping/pong.

### Phase 2: Document Transfer & Display
1.  Implement the `SyncEnvelope` framing and protobuf codec.
2.  Mac: Build tab-based UI to open one or more PDFs; reconstruct `page_drawings` from stroke outline annotations, strip those annotations from the PDF bytes, and transmit the stripped PDF plus `page_drawings` as `PdfData`; send `PdfClose` when a tab is closed.
3.  iPad: Receive `PdfData` payloads; display each document in its own tab using `PDFView` (PDFKit); replace the cached PDF silently on re-send; close the tab on `PdfClose`; pre-allocate per-page `PKDrawing` cache from `page_drawings`.

### Phase 3: PencilKit & Drawing Sync
1.  iPad: Create one `PKCanvasView` per PDF page, sized and positioned over each page's frame in the `PDFView` layout; keep all canvases in sync with `PDFView` scroll and zoom via `PDFViewDelegate`.
2.  iPad: On `PdfData` receipt, load each page's `PKDrawing` from `page_drawings` into the corresponding canvas (empty drawing for pages absent from the map).
3.  iPad: Implement per-page stroke diffing in `canvasViewDrawingDidChange`; maintain a `stroke_id`→`PKStroke` cache per page.
4.  iPad: Serialize stroke deltas as `StrokeBatch` (additions) and `StrokeRemove` (deletions/erases/undos) and transmit to Mac.
5.  Mac: Receive `StrokeBatch`/`StrokeRemove`, merge into the in-memory per-page `PKDrawing`, and render on the Mac's corresponding PDF view.
6.  Mac: On document open, read stroke outline annotations and reconstruct the per-page `PKDrawing` cache from their geometry.
7.  Mac: Before sending `PdfData`, strip all stroke annotations from the PDF bytes and populate `page_drawings`; on document save, convert each page's `PKDrawing` strokes into filled outline paths and store as PDF annotations; preserve non-stroke annotations untouched.
8.  Mac: Maintain the global document-level undo stack (covering both Mac document edits and iPad stroke batches in arrival order). Implement `Undo`/`Redo` toolbar buttons on the Mac. On receiving `Undo`/`Redo` from the iPad (or triggering it locally), apply the action: if stroke-related, push `StrokeRemove`/`StrokeBatch` to the iPad; if non-stroke, re-send `PdfData` with the updated document. The iPad never independently invokes its `PKCanvasView` `UndoManager` for undo/redo.

### Phase 4: Refinement & Optimization
1.  Profile latency using Instruments and optimize data serialization.
2.  Add error handling for network drops and seamless reconnection.
3.  Handle on-disk file changes: auto-reload when there are no unsaved changes; otherwise prompt the user to reload from disk or keep the in-memory version, marking the document as conflicted until the user resolves it. If the user keeps the in-memory version, the next save overwrites the original file.
4.  Handle large PDF updates efficiently (e.g., delta or incremental re-send if the Mac PDF changes frequently).

## Verification & Testing
*   **Latency Testing:** Measure the millisecond delta between stroke completion on the iPad and appearance on the Mac. Target: < 50ms on local Wi-Fi.
*   **Network Resiliency:** Use Network Link Conditioner to simulate high packet loss and high latency. Verify that QUIC correctly recovers without dropping strokes or deadlocking.
*   **Memory Profiling:** Ensure the iPad does not leak memory when repeatedly opening and closing large PDFs.
*   **Fidelity:** Verify that stroke thickness, color, and opacity render identically on both macOS and iPadOS.
*   **Persistence Round-trip:** Save a marked-up PDF, reopen it in AirPDF, and verify that strokes remain editable from reconstructed outline geometry. Also open the saved file in Apple Preview and PDF Expert to confirm the filled stroke outlines render identically to the original `PKCanvasView` appearance — including variable width and tapered ends. Print the PDF and verify visual match.
*   **Conflict Handling:** Verify that external file changes trigger the expected reload/conflict flow, including overwrite-on-save after the user elects to keep the in-memory version.

## Migration & Rollback
*   As this is a greenfield application, there is no legacy data to migrate.
