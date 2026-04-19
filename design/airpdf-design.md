# AirPDF Design Document

## Background & Motivation
AirPDF aims to turn the iPad into a real-time, low-latency drawing tablet for marking up PDFs that are hosted on a Mac. This application allows users to leverage the superior Apple Pencil drawing experience natively on an iPad without transferring source files between devices. The core focus is absolute minimal latency, high-performance rendering (leveraging Metal and native frameworks), and robust device communication over local networks.

## Scope & Impact
*   **macOS Application:** Acts as the source of truth, handling PDF document management, file system interactions, and the primary network host.
*   **iPadOS Application:** Acts as a thin client for storage but renders the PDF locally for maximum responsiveness. Provides the PencilKit interface and transmits finalized drawing data.
*   **Network Synchronization:** Implementation of Apple's Network framework using the QUIC protocol to ensure low-latency data transmission with built-in reliability and security.
*   **Data Serialization:** Efficient diffing and synchronization of `PKStroke` data.
*   **Extensibility:** Forward-compatible data structures that can support annotations, text boxes, and layers in future iterations.

## Proposed Solution

### 1. Network Architecture: QUIC (NWProtocolQUIC)
We will utilize Apple's `Network` framework configured for the QUIC protocol. QUIC provides the perfect balance between the ultra-low latency of UDP and the reliability of TCP, avoiding head-of-line blocking while maintaining connection security and data integrity.
*   **Mac (Host):** Runs an `NWListener` broadcasting the service or listening on a specific port.
*   **iPad (Client):** Connects to the Mac's IP address manually via an `NWConnection`.
*   **Messaging Protocol:** A custom binary or Codable-based framing protocol over QUIC streams to differentiate between command messages (e.g., "Load PDF", "Change Page") and data payloads (e.g., "New Stroke Data", "Undo"). Edit here: Use protobuf, and define a proto schema for the messages.

### 2. PDF Rendering Strategy: iPad Local Rendering
To minimize bandwidth after the initial connection and provide the smoothest zooming/panning experience on the iPad:
*   The Mac will securely transmit the raw PDF file to the iPad over a dedicated QUIC stream upon document open.
*   The iPad stores this PDF ephemerally (in memory or a temporary cache) and renders it natively using `PDFKit` (which is backed by Metal).
*   The PencilKit `PKCanvasView` will be overlaid transparently on top of the PDF view.

### 3. Drawing Synchronization: Finalized Strokes
To optimize network traffic and simplify conflict resolution, the synchronization will operate at the finalized stroke level.
*   **Capture:** The iPad app listens to `PKCanvasViewDelegate`'s `canvasViewDrawingDidChange(_:)`.
*   **Diffing:** The app maintains a cache of previously known strokes. Upon a change, it identifies the delta (new or removed strokes).
*   **Transmission:** Only the delta (using `PKStroke` data representation) is sent to the Mac.
*   **Reconstruction:** The Mac receives the stroke data, deserializes it, and appends it to its own internal `PKDrawing` model, updating its display synchronously.

### Data Structures & Extensibility
The payload format over the network will be designed generically:
```swift
struct SyncEnvelope: Codable {
    let type: PayloadType // .pdfData, .strokeAdd, .strokeRemove, .pageTurn
    let data: Data
    let timestamp: TimeInterval
}
```
This envelope structure ensures that future features (like `.textAnnotation` or `.layerState`) can be added without fundamentally rewriting the networking layer.

## Alternatives Considered
*   **Custom UDP Networking:** Rejected in favor of QUIC. While UDP offers the absolute lowest theoretical latency, it requires a massive development effort to manually implement packet ordering, retransmissions for critical data (like stroke data), and security. QUIC provides these automatically with negligible latency overhead.
*   **Mac Remote Rendering (Image Streaming):** Rejected. Having the Mac stream rendered frames to the iPad creates a "truer" thin client but significantly degrades the iPad's zooming and panning performance. It also requires substantially more continuous bandwidth, making it susceptible to network jitters.
*   **Real-time Continuous Stroke Streaming:** Rejected for initial scope. Streaming continuous touch points over the network introduces significant complexity in managing the "in-progress" stroke state versus the finalized `PKStroke`. Finalized strokes provide a stable, highly reliable initial implementation.

## Implementation Plan
### Phase 1: Core Networking & Discovery
1.  Implement `NWListener` on macOS.
2.  Implement `NWConnection` on iPadOS with a manual IP entry UI.
3.  Establish a basic QUIC connection and verify bi-directional ping/pong latency.

### Phase 2: Document Transfer & Display
1.  Implement the `SyncEnvelope` protocol.
2.  Mac: Build UI to open a PDF and transmit the file payload.
3.  iPad: Receive PDF payload, load it into a temporary directory, and render using `PDFView` (PDFKit).

### Phase 3: PencilKit & Drawing Sync
1.  iPad: Overlay a transparent `PKCanvasView` on the PDF.
2.  iPad: Implement stroke diffing logic in `canvasViewDrawingDidChange`.
3.  iPad: Serialize and transmit new/removed strokes.
4.  Mac: Receive stroke data, deserialize, and render on the Mac's corresponding PDF view.

### Phase 4: Refinement & Optimization
1.  Implement page synchronization (turning a page on Mac turns it on iPad, and vice versa).
2.  Profile latency using Instruments and optimize data serialization.
3.  Add error handling for network drops and seamless reconnection.

## Verification & Testing
*   **Latency Testing:** Measure the millisecond delta between stroke completion on the iPad and appearance on the Mac. Target: < 50ms on local Wi-Fi.
*   **Network Resiliency:** Use Network Link Conditioner to simulate high packet loss and high latency. Verify that QUIC correctly recovers without dropping strokes or deadlocking.
*   **Memory Profiling:** Ensure the iPad does not leak memory when repeatedly opening and closing large PDFs.
*   **Fidelity:** Verify that stroke thickness, color, and opacity render identically on both macOS and iPadOS.

## Migration & Rollback
*   As this is a greenfield application, there is no legacy data to migrate.

