#if os(iOS)
import Foundation
import Combine
import Network
import os

/// Manages the iPad's QUIC connection to the Mac host.
/// Handles Hello/Welcome handshake and session resume.
/// Liveness is handled by QUIC transport-level keepalive.
@MainActor
final class QuicClient: ObservableObject {
    enum State: Equatable {
        case disconnected
        case connecting
        case handshaking
        case connected(sessionId: String)
        case failed(String)
    }

    @Published private(set) var state: State = .disconnected
    /// Fingerprint of the Mac's server certificate (read from SecTrust in verify block).
    @Published private(set) var sessionFingerprint: String = ""
    /// Fingerprint of our own ephemeral client certificate.
    @Published private(set) var ownFingerprint: String = ""

    var onMessage: ((Airpdf_V1_SyncEnvelope) -> Void)?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "dev.airpdf.ipad.quic", qos: .userInitiated)
    private let logger = Logger(subsystem: "dev.airpdf.ipad", category: "QuicClient")

    private var receiveBuffer = Data()
    private var lastSessionId: String?
    private var keepaliveTimer: DispatchSourceTimer?

    init() {}

    // MARK: - Connect / Disconnect

    func connect(to endpoint: NWEndpoint) {
        guard state == .disconnected else { return }
        state = .connecting

        let quicOptions = NWProtocolQUIC.Options(alpn: ["airpdf"])
        quicOptions.direction = .bidirectional

        // Generate ephemeral client identity. The server requires a client cert (mTLS),
        // so we must present one and respond to the CertificateRequest via challenge_block.
        do {
            let identity = try TLSIdentity.ephemeral()
            sec_protocol_options_set_local_identity(quicOptions.securityProtocolOptions, identity.secIdentity)
            sec_protocol_options_set_challenge_block(
                quicOptions.securityProtocolOptions,
                { _, complete in complete(identity.secIdentity) },
                queue
            )
            let fp = TLSFingerprint.of(identity.certificate)
            Task { @MainActor in self.ownFingerprint = fp }
        } catch {
            logger.error("TLSIdentity.ephemeral() failed: \(error)")
        }

        // Read the Mac's server cert fingerprint from SecTrust during the verify block.
        sec_protocol_options_set_verify_block(
            quicOptions.securityProtocolOptions,
            { [weak self] _, trust, completion in
                let fp = SecTrustGetCertificateAtIndex(sec_trust_copy_ref(trust).takeRetainedValue(), 0)
                    .map { TLSFingerprint.of($0) } ?? "unknown"
                Task { @MainActor in self?.sessionFingerprint = fp }
                completion(true)
            },
            queue
        )
        // Disable session resumption so the verify block always fires on every connection.
        sec_protocol_options_set_tls_resumption_enabled(quicOptions.securityProtocolOptions, false)

        let params = NWParameters(quic: quicOptions)
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] s in Task { @MainActor in self?.handleConnectionState(s) } }
        conn.start(queue: queue)
    }

    func disconnect() {
        lastSessionId = nil
        teardown(reason: nil)
    }

    // MARK: - Send

    func send(_ envelope: Airpdf_V1_SyncEnvelope) {
        guard let data = try? FrameCodec.encode(envelope) else { return }
        connection?.send(content: data, completion: .idempotent)
    }

    // MARK: - Connection state

    private func handleConnectionState(_ s: NWConnection.State) {
        switch s {
        case .ready:
            state = .handshaking
            startReceiving()
            sendHello()
        case .failed(let err):
            logger.error("Connection failed: \(err)")
            state = .failed(err.localizedDescription)
            teardown(reason: nil)
        case .cancelled:
            if case .connected = state { } else { state = .disconnected }
        default: break
        }
    }

    // MARK: - Handshake

    private func sendHello() {
        var hello = Airpdf_V1_Hello()
        hello.protocolVersion = AirPDFConstants.protocolVersion
        hello.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        if let sid = lastSessionId { hello.resumeSessionID = sid }
        send(.wrap(.hello(hello)))
    }

    private func handleWelcome(_ welcome: Airpdf_V1_Welcome) {
        let sid = welcome.sessionID
        if let last = lastSessionId, last != sid {
            logger.info("New session (was \(last)), discarding cached state")
        }
        lastSessionId = sid
        state = .connected(sessionId: sid)
        logger.info("Connected, session=\(sid)")
        startKeepalive()
    }

    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.send(.wrap(.heartbeat(Airpdf_V1_Heartbeat()))) }
        }
        timer.resume()
        keepaliveTimer = timer
    }

    // MARK: - Receive loop

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty { self.receiveBuffer.append(data); self.drainBuffer() }
                if let error { self.logger.error("Receive error: \(error)"); self.teardown(reason: error.localizedDescription); return }
                if isComplete { self.teardown(reason: nil); return }
                self.startReceiving()
            }
        }
    }

    private func drainBuffer() {
        while let envelope = try? FrameCodec.decode(from: &receiveBuffer) { handle(envelope) }
    }

    private func handle(_ envelope: Airpdf_V1_SyncEnvelope) {
        switch envelope.payload.body {
        case .welcome(let w): handleWelcome(w)
        case .error(let err):
            logger.error("Server error \(err.code.rawValue): \(err.message)")
            if err.code == .unsupportedVersion { teardown(reason: err.message) }
        default: onMessage?(envelope)
        }
    }

    // MARK: - Teardown

    private func teardown(reason: String?) {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        connection?.cancel()
        connection = nil
        receiveBuffer = Data()
        sessionFingerprint = ""
        ownFingerprint = ""
        state = reason != nil ? .failed(reason!) : .disconnected
    }
}
#endif
