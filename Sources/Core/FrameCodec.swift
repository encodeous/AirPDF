import Foundation
import SwiftProtobuf

/// Framing: each message is a 4-byte big-endian length prefix followed by the serialized SyncEnvelope.
enum FrameCodec {
    enum Error: Swift.Error {
        case messageTooLarge(Int)
        case incomplete
    }

    static let headerSize = 4
    static let maxMessageSize = 64 * 1024 * 1024 // 64 MB

    /// Encode a SyncEnvelope into a framed Data (length prefix + body).
    static func encode(_ envelope: Airpdf_V1_SyncEnvelope) throws -> Data {
        let body = try envelope.serializedData()
        guard body.count <= maxMessageSize else {
            throw Error.messageTooLarge(body.count)
        }
        var frame = Data(capacity: headerSize + body.count)
        var length = UInt32(body.count).bigEndian
        frame.append(contentsOf: withUnsafeBytes(of: &length) { Data($0) })
        frame.append(body)
        return frame
    }

    /// Attempt to decode one SyncEnvelope from the front of `buffer`.
    /// On success, removes the consumed bytes from `buffer` and returns the envelope.
    /// Returns nil if the buffer doesn't yet contain a complete message.
    static func decode(from buffer: inout Data) throws -> Airpdf_V1_SyncEnvelope? {
        guard buffer.count >= headerSize else { return nil }
        let length = Int(buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
        })
        guard buffer.count >= headerSize + length else { return nil }
        let start = buffer.startIndex + headerSize
        let envelope = try Airpdf_V1_SyncEnvelope(serializedBytes: buffer[start ..< start + length])
        buffer = buffer.dropFirst(headerSize + length)
        return envelope
    }
}
