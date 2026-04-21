#if os(macOS)
import Foundation
import Network
import os

/// Represents one connected iPad client. Handles the Hello/Welcome handshake
/// and message framing. Liveness is handled by QUIC transport-level keepalive.
final class ClientConnection: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private let logger = Logger(subsystem: "dev.airpdf.mac", category: "ClientConnection")

    var onDisconnect: (() -> Void)?
    var onSessionEstablished: ((String) -> Void)?
    var onMessage: ((Airpdf_V1_SyncEnvelope) -> Void)?

    private(set) var sessionId: String?
    private var receiveBuffer = Data()

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    self.logger.info("Client connection ready, awaiting Hello")
                    self.startReceiving()
                case .failed(let err):
                    self.logger.error("Client connection failed: \(err)")
                    self.teardown()
                case .cancelled:
                    self.teardown()
                default: break
                }
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ envelope: Airpdf_V1_SyncEnvelope) {
        guard let data = try? FrameCodec.encode(envelope) else { return }
        connection.send(content: data, completion: .idempotent)
    }

    func sendError(_ code: Airpdf_V1_ErrorCode, message: String) {
        var err = Airpdf_V1_Error()
        err.code = code
        err.message = message
        send(.wrap(.error(err)))
    }

    // MARK: - Receive loop

    private func startReceiving() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drainBuffer()
            }
            if let error {
                self.logger.error("Receive error: \(error)")
                self.teardown()
                return
            }
            if isComplete {
                self.teardown()
                return
            }
            self.startReceiving()
        }
    }

    private func drainBuffer() {
        while let envelope = try? FrameCodec.decode(from: &receiveBuffer) {
            handle(envelope)
        }
    }

    // MARK: - Message handling

    private func handle(_ envelope: Airpdf_V1_SyncEnvelope) {
        switch envelope.payload.body {
        case .hello(let hello):
            handleHello(hello)
        default:
            if sessionId != nil { onMessage?(envelope) }
        }
    }

    private func handleHello(_ hello: Airpdf_V1_Hello) {
        guard hello.protocolVersion == AirPDFConstants.protocolVersion else {
            sendError(.unsupportedVersion, message: "Expected protocol version \(AirPDFConstants.protocolVersion)")
            cancel()
            return
        }
        let sid = hello.resumeSessionID.isEmpty ? UUID().uuidString : hello.resumeSessionID
        sessionId = sid

        var welcome = Airpdf_V1_Welcome()
        welcome.protocolVersion = AirPDFConstants.protocolVersion
        welcome.sessionID = sid
        send(.wrap(.welcome(welcome)))

        logger.info("Session established: \(sid)")
        DispatchQueue.main.async { [weak self] in self?.onSessionEstablished?(sid) }
    }

    // MARK: - Teardown

    private func teardown() {
        connection.cancel()
        DispatchQueue.main.async { [weak self] in self?.onDisconnect?() }
    }
}
#endif
