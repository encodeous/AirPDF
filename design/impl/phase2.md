# AirPDF Phase 2 — Document Transfer & Display

## Status: Complete

## What Was Built

### Document Transfer

**Mac (`Sources/macOS/`):**
- `DocumentSession` extended to hold a live `PDFDocument` and `pageDrawings: [Int: Data]`.
- `PDFStripper` (Core) — no-op stub returning raw `dataRepresentation()`; Phase 3 will strip stroke annotations.
- `AppModel.makePdfData(for:)` — calls `PDFStripper.strip`, computes `CryptoKit.SHA256` digest, populates all `PdfData` fields. Sends on document open and on client reconnect.
- Security-scoped URL access held open for the document's lifetime; released on close.
- `PdfData` sent with `.contentProcessed` completion to avoid silent drops on large payloads.

**iPad (`Sources/iPad/`):**
- `DocumentStore` — `@MainActor ObservableObject` holding received `TabDocument` values. Verifies `SHA-256(content) == contentSha256` on receipt; discards on mismatch.
- `ConnectionViewModel` wires `QuicClient.onMessage` to `DocumentStore.receive`/`close`. Clears store on disconnect.

### PDF Display

**Mac:**
- `MacPDFView` — `NSViewRepresentable` wrapping `PDFKit.PDFView` (`autoScales`, `singlePageContinuous`).
- `MacContentView` detail pane shows `MacPDFView` for the selected document; `ContentUnavailableView` otherwise.
- Sidebar shows persistent server status footer (stopped / listening / connected).
- Each sidebar row has an `×` button to close that document.

**iPad:**
- `PDFTabView` — `Picker` (segmented, shown only when >1 doc) + full-screen `PDFView` per document.
- `ConnectionView` connected state shows `PDFTabView` with fingerprint toolbar and Disconnect button.

### mTLS Identity & Fingerprinting

Both sides generate an ephemeral self-signed P256 certificate each launch via `TLSIdentity.ephemeral()` (Core, cross-platform). Certificates are not persisted — they are identity tokens for the current session only.

**Mac server (`QuicServer`):**
- Sets `sec_protocol_options_set_peer_authentication_required(true)` — forces TLS CertificateRequest, making the client present its cert.
- Sets `sec_protocol_options_set_tls_resumption_enabled(false)` — ensures every connection does a full handshake.
- Stores `ownFingerprint = TLSFingerprint.of(identity.certificate)` for display.

**Mac client handler (`ClientConnection`):**
- On `.ready`, reads peer cert via `NWProtocolQUIC.definition` metadata + `sec_protocol_metadata_access_peer_certificate_chain`. This works for listener-accepted QUIC connections when `peer_authentication_required` is set.
- Passes `clientFingerprint` to `QuicServer` via `onSessionEstablished`.

**iPad client (`QuicClient`):**
- Generates ephemeral identity; sets it via `set_local_identity` and `set_challenge_block` (responds to server's CertificateRequest).
- Reads Mac server cert fingerprint from `SecTrust` in `set_verify_block`.
- Exposes `ownFingerprint` (our cert) and `sessionFingerprint` (Mac's cert).

**`TLSFingerprint` (Core):** `SHA256(SecCertificateCopyData(cert)).prefix(4)` → 8 hex chars.

**UI verification:**
- Mac popover (click green dot): shows `Mac: xxxx` and `iPad: xxxx`.
- iPad toolbar: shows `Mac: xxxx` and `iPad: xxxx`.
- User compares both sides match for manual out-of-band verification.

## Key Decisions

| Decision | Rationale |
|----------|-----------|
| `PDFStripper` as no-op | Phase 3 adds real annotation stripping; foundation is in place |
| `.contentProcessed` send completion | Prevents silent drops on large PdfData payloads |
| `peer_authentication_required` on server | Only way to make `NWProtocolTLS.Metadata` expose peer cert on listener-accepted QUIC connections |
| Ephemeral (not persistent) client certs | Avoids key distribution complexity; user verifies manually each session |
| Fingerprint via cert DER hash | Stable across session resumption; no key export needed |

## Files Created

| File | Purpose |
|------|---------|
| `Sources/Core/PDFStripper.swift` | Strip-and-serialize PDF (no-op stub) |
| `Sources/Core/TLSIdentity.swift` | Cross-platform ephemeral self-signed cert generation |
| `Sources/Core/TLSFingerprint.swift` | SHA-256 cert fingerprint helper |
| `Sources/macOS/MacPDFView.swift` | NSViewRepresentable PDFView wrapper |
| `Sources/iPad/DocumentStore.swift` | Observable document state + SHA-256 integrity check |
| `Sources/iPad/PDFTabView.swift` | Segmented-picker tab PDF viewer |

## Files Modified

| File | Change |
|------|--------|
| `Sources/macOS/DocumentSession.swift` | Added `pdfDocument` + `pageDrawings`; changed to `class` |
| `Sources/macOS/AppModel.swift` | Real PdfData send; security-scoped URL lifecycle |
| `Sources/macOS/ContentView.swift` | MacPDFView detail pane; sidebar status footer; close buttons; fingerprint popover |
| `Sources/macOS/Networking/QuicServer.swift` | mTLS: peer auth required, resumption disabled, own fingerprint |
| `Sources/macOS/Networking/ClientConnection.swift` | Peer cert fingerprint from TLS metadata post-handshake |
| `Sources/iPad/ConnectionViewModel.swift` | DocumentStore + onMessage wiring |
| `Sources/iPad/ConnectionView.swift` | PDFTabView connected state; fingerprint toolbar |
| `Sources/iPad/Networking/QuicClient.swift` | mTLS client cert; server cert fingerprint from verify block |
| `proto/airpdf.proto` | (no net changes — field 4 added and removed during iteration) |
