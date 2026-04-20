import Foundation

public enum AirPDFProtocol {
    public static let version = "1.0.0"
}

public struct SyncEnvelope: Codable, Sendable, Equatable {
    public var timestampMs: Int64
    public var payload: Payload

    public init(timestampMs: Int64, payload: Payload) {
        self.timestampMs = timestampMs
        self.payload = payload
    }
}

public enum Payload: Codable, Sendable, Equatable {
    case ping(Ping)
    case pong(Pong)
    case hello(Hello)
    case welcome(Welcome)
    case pdfData(PdfData)
    case strokeBatch(StrokeBatch)
    case strokeRemove(StrokeRemove)
    case pdfClose(PdfClose)
    case undo(Undo)
    case redo(Redo)
    case error(SyncError)

    private enum CodingKeys: String, CodingKey {
        case kind
        case ping
        case pong
        case hello
        case welcome
        case pdfData
        case strokeBatch
        case strokeRemove
        case pdfClose
        case undo
        case redo
        case error
    }

    private enum Kind: String, Codable {
        case ping
        case pong
        case hello
        case welcome
        case pdfData
        case strokeBatch
        case strokeRemove
        case pdfClose
        case undo
        case redo
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .ping:
            self = .ping(try container.decode(Ping.self, forKey: .ping))
        case .pong:
            self = .pong(try container.decode(Pong.self, forKey: .pong))
        case .hello:
            self = .hello(try container.decode(Hello.self, forKey: .hello))
        case .welcome:
            self = .welcome(try container.decode(Welcome.self, forKey: .welcome))
        case .pdfData:
            self = .pdfData(try container.decode(PdfData.self, forKey: .pdfData))
        case .strokeBatch:
            self = .strokeBatch(try container.decode(StrokeBatch.self, forKey: .strokeBatch))
        case .strokeRemove:
            self = .strokeRemove(try container.decode(StrokeRemove.self, forKey: .strokeRemove))
        case .pdfClose:
            self = .pdfClose(try container.decode(PdfClose.self, forKey: .pdfClose))
        case .undo:
            self = .undo(try container.decode(Undo.self, forKey: .undo))
        case .redo:
            self = .redo(try container.decode(Redo.self, forKey: .redo))
        case .error:
            self = .error(try container.decode(SyncError.self, forKey: .error))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ping(value):
            try container.encode(Kind.ping, forKey: .kind)
            try container.encode(value, forKey: .ping)
        case let .pong(value):
            try container.encode(Kind.pong, forKey: .kind)
            try container.encode(value, forKey: .pong)
        case let .hello(value):
            try container.encode(Kind.hello, forKey: .kind)
            try container.encode(value, forKey: .hello)
        case let .welcome(value):
            try container.encode(Kind.welcome, forKey: .kind)
            try container.encode(value, forKey: .welcome)
        case let .pdfData(value):
            try container.encode(Kind.pdfData, forKey: .kind)
            try container.encode(value, forKey: .pdfData)
        case let .strokeBatch(value):
            try container.encode(Kind.strokeBatch, forKey: .kind)
            try container.encode(value, forKey: .strokeBatch)
        case let .strokeRemove(value):
            try container.encode(Kind.strokeRemove, forKey: .kind)
            try container.encode(value, forKey: .strokeRemove)
        case let .pdfClose(value):
            try container.encode(Kind.pdfClose, forKey: .kind)
            try container.encode(value, forKey: .pdfClose)
        case let .undo(value):
            try container.encode(Kind.undo, forKey: .kind)
            try container.encode(value, forKey: .undo)
        case let .redo(value):
            try container.encode(Kind.redo, forKey: .kind)
            try container.encode(value, forKey: .redo)
        case let .error(value):
            try container.encode(Kind.error, forKey: .kind)
            try container.encode(value, forKey: .error)
        }
    }
}

public struct Ping: Codable, Sendable, Equatable {
    public var sequence: UInt64

    public init(sequence: UInt64) {
        self.sequence = sequence
    }
}

public struct Pong: Codable, Sendable, Equatable {
    public var sequence: UInt64

    public init(sequence: UInt64) {
        self.sequence = sequence
    }
}

public struct Hello: Codable, Sendable, Equatable {
    public var protocolVersion: String
    public var appVersion: String

    public init(protocolVersion: String, appVersion: String) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
    }
}

public struct Welcome: Codable, Sendable, Equatable {
    public var protocolVersion: String
    public var sessionID: String

    public init(protocolVersion: String, sessionID: String) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
    }
}

public struct PdfData: Codable, Sendable, Equatable {
    public var documentID: String
    public var fileName: String
    public var content: Data
    public var sha256: Data
    public var pageDrawings: [UInt32: Data]
    public var pageCount: UInt32

    public init(
        documentID: String,
        fileName: String,
        content: Data,
        sha256: Data,
        pageDrawings: [UInt32: Data],
        pageCount: UInt32
    ) {
        self.documentID = documentID
        self.fileName = fileName
        self.content = content
        self.sha256 = sha256
        self.pageDrawings = pageDrawings
        self.pageCount = pageCount
    }
}

public struct PdfClose: Codable, Sendable, Equatable {
    public var documentID: String

    public init(documentID: String) {
        self.documentID = documentID
    }
}

public struct StrokeBatch: Codable, Sendable, Equatable {
    public var documentID: String
    public var pageIndex: UInt32
    public var strokes: [StrokeEntry]

    public init(documentID: String, pageIndex: UInt32, strokes: [StrokeEntry]) {
        self.documentID = documentID
        self.pageIndex = pageIndex
        self.strokes = strokes
    }
}

public struct StrokeEntry: Codable, Sendable, Equatable {
    public var strokeID: String
    public var pkStrokeData: Data

    public init(strokeID: String, pkStrokeData: Data) {
        self.strokeID = strokeID
        self.pkStrokeData = pkStrokeData
    }
}

public struct StrokeRemove: Codable, Sendable, Equatable {
    public var documentID: String
    public var pageIndex: UInt32
    public var strokeID: String

    public init(documentID: String, pageIndex: UInt32, strokeID: String) {
        self.documentID = documentID
        self.pageIndex = pageIndex
        self.strokeID = strokeID
    }
}

public struct Undo: Codable, Sendable, Equatable {
    public var documentID: String

    public init(documentID: String) {
        self.documentID = documentID
    }
}

public struct Redo: Codable, Sendable, Equatable {
    public var documentID: String

    public init(documentID: String) {
        self.documentID = documentID
    }
}

public struct SyncError: Codable, Sendable, Equatable {
    public var code: ErrorCode
    public var message: String

    public init(code: ErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum ErrorCode: String, Codable, Sendable, Equatable {
    case unspecified
    case invalidPayload
    case documentNotFound
    case unsupportedVersion
    case internalError
    case strokeNotFound
}
