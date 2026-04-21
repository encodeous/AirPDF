# AirPDF

Turn an iPad into a real-time Apple Pencil drawing tablet for marking up PDFs hosted on a Mac.

## Requirements

- Xcode 16+ (Xcode 26 recommended)
- macOS 14+ (Mac app)
- iPadOS 17+ (iPad app)
- Both devices on the same local network

## Setup

1. Open `AirPDF.xcodeproj`
2. Select your team in **Signing & Capabilities** for both the macOS and iOS destinations
3. Build and run

## Protobuf Code Generation

The generated Swift file (`Sources/Generated/airpdf.pb.swift`) is committed to the repo. You only need to regenerate it if you modify `proto/airpdf.proto`.

**To regenerate:**

```bash
# 1. Build protoc-gen-swift from the Xcode package checkout
CHECKOUT=$(find ~/Library/Developer/Xcode/DerivedData -path "*/checkouts/swift-protobuf" -type d 2>/dev/null | head -1)
swift build --package-path "$CHECKOUT" --product protoc-gen-swift -c release

# 2. Run protoc
protoc \
  --plugin="protoc-gen-swift=$CHECKOUT/.build/release/protoc-gen-swift" \
  --swift_out=Sources/Generated \
  proto/airpdf.proto
```

After regenerating, commit `Sources/Generated/airpdf.pb.swift`.

> **Note:** Do not add `Visibility=Public` to the `--swift_opt` flags. The generated file lives in the same module as the app target and does not need public visibility.

## Project Structure

```
AirPDF/                  # Xcode app entry point (AirPDFApp.swift)
Sources/
  Core/                  # Shared: FrameCodec, AirPDFConstants, SyncEnvelope helpers
  Generated/             # Generated protobuf Swift file (do not edit manually)
  macOS/                 # Mac-only: QuicServer, ClientConnection, TLSIdentity, AppModel, UI
  iPad/                  # iPad-only: QuicClient, BonjourBrowser, ConnectionView
proto/
  airpdf.proto           # Canonical wire protocol schema
design/
  airpdf-design.md       # Full design document
```

## Architecture

See [`design/airpdf-design.md`](design/airpdf-design.md) for the full design doc and [`proto/airpdf.proto`](proto/airpdf.proto) for the wire protocol schema.
