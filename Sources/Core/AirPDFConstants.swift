import Foundation

enum AirPDFConstants {
    static let bonjourServiceType = "_airpdf._udp"
    static let bonjourDomain = "local."
    static let serverPort: UInt16 = 9443
    static let protocolVersion = "1.0.0"
    static let sessionTimeoutSeconds: TimeInterval = 60
    static let heartbeatIntervalSeconds: TimeInterval = 10
    static let pkDrawingAttachmentName = "airpdf_drawing.pkdata"
}
