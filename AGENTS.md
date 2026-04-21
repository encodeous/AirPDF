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

- [ ] Phase 1: Core Networking & Discovery
- [ ] Phase 2: Document Transfer & Display
- [ ] Phase 3: PencilKit & Drawing Sync
- [ ] Phase 4: Refinement & Optimization

**Current phase:** Not started  
**Last worked on:** —

## Assumptions

- v1 targets a single Mac ↔ single iPad topology.
- The same PDF cannot be opened twice simultaneously in the same Mac session.
- `document_id` is ephemeral (assigned on open, not derived from path or content).
- No password-protected or malformed PDFs — rejected cleanly.
- No PDF size limit.
- In-session PKDrawing fidelity is perfect; fidelity loss only occurs if the `airpdf_drawing.pkdata` attachment is stripped by a third-party editor.

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
