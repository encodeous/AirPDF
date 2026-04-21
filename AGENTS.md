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
- [ ] Phase 3: PencilKit & Drawing Sync
- [ ] Phase 4: Refinement & Optimization

**Current phase:** Phase 2 3
**Last worked on:** 2026-04-20

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
