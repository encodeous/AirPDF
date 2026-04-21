#if os(macOS)
import Foundation
import Combine
import Network
import os

/// Manages the QUIC server: TLS identity, single-client enforcement, Bonjour advertisement,
/// Hello/Welcome handshake, heartbeat, and session timeout.
@MainActor
final class QuicServer: ObservableObject {
    enum State: Equatable {
        case stopped
        case running(port: UInt16)
        case clientConnected(sessionId: String, fingerprint: String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var ownFingerprint: String = ""

    private var listener: NWListener?
    private var activeClient: ClientConnection?
    private let queue = DispatchQueue(label: "dev.airpdf.mac.quic", qos: .userInitiated)
    private let logger = Logger(subsystem: "dev.airpdf.mac", category: "QuicServer")

    // Injected by AppModel so the server can push PdfData on reconnect
    var onClientConnected: ((ClientConnection) -> Void)?
    var onClientDisconnected: (() -> Void)?

    func start() throws {
        guard state == .stopped else { return }

        let identity = try TLSIdentity.ephemeral()

        let quicOptions = NWProtocolQUIC.Options(alpn: ["airpdf"])
        quicOptions.direction = .bidirectional
        quicOptions.idleTimeout = 30 * 1000 // 30 seconds
        sec_protocol_options_set_local_identity(
            quicOptions.securityProtocolOptions,
            identity.secIdentity
        )
        sec_protocol_options_set_min_tls_protocol_version(
            quicOptions.securityProtocolOptions,
            .TLSv12
        )
        // Disable session resumption so every connection does a full handshake.
        sec_protocol_options_set_tls_resumption_enabled(
            quicOptions.securityProtocolOptions, false
        )
        // Require client certificate (mTLS). Handshake fails if client doesn't present one.
        sec_protocol_options_set_peer_authentication_required(
            quicOptions.securityProtocolOptions, true
        )
        // Accept all client certificates; fingerprint extracted post-handshake.
        sec_protocol_options_set_verify_block(
            quicOptions.securityProtocolOptions,
            { _, _, completion in completion(true) },
            queue
        )
        // Store our own fingerprint for display
        self.ownFingerprint = TLSFingerprint.of(identity.certificate)

        let params = NWParameters(quic: quicOptions)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: AirPDFConstants.serverPort)!)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.handleIncoming(conn) }
        }
        listener.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            Task { @MainActor in
                switch s {
                case .ready:
                    self.state = .running(port: AirPDFConstants.serverPort)
                    self.logger.info("QUIC server ready on port \(AirPDFConstants.serverPort)")
                case .failed(let err):
                    self.logger.error("Listener failed: \(err)")
                    self.state = .stopped
                case .cancelled:
                    self.state = .stopped
                default: break
                }
            }
        }
        advertiseBonjour(on: listener)
        listener.start(queue: queue)
    }

    func stop() {
        activeClient?.cancel()
        activeClient = nil
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    func disconnectClient() {
        activeClient?.cancel()
        // state update handled by onDisconnect callback
    }

    // MARK: - Incoming connection

    private func handleIncoming(_ conn: NWConnection) {
        let client = ClientConnection(connection: conn, queue: queue)
        client.onDisconnect = { [weak self, weak client] in
            Task { @MainActor in
                guard let self, let client else { return }
                if self.activeClient === client {
                    self.activeClient = nil
                    self.state = .running(port: AirPDFConstants.serverPort)
                    self.onClientDisconnected?()
                }
            }
        }
        client.onSessionEstablished = { [weak self] sessionId, fingerprint in
            Task { @MainActor in
                guard let self else { return }
                if self.activeClient != nil {
                    client.sendError(.clientAlreadyConnected, message: "A client is already connected.")
                    client.cancel()
                    self.logger.warning("Rejected second client connection (post-handshake)")
                    return
                }
                self.activeClient = client
                self.state = .clientConnected(sessionId: sessionId, fingerprint: fingerprint)
                self.onClientConnected?(client)
            }
        }
        client.start()
    }

    // MARK: - Bonjour

    private func advertiseBonjour(on listener: NWListener) {
        let serviceName = Host.current().localizedName ?? "AirPDF Mac"
        listener.service = NWListener.Service(
            name: serviceName,
            type: AirPDFConstants.bonjourServiceType
        )
        listener.serviceRegistrationUpdateHandler = { change in
            switch change {
            case .add(let endpoint):
                self.logger.info("Bonjour registered: \(String(describing: endpoint))")
            case .remove(let endpoint):
                self.logger.info("Bonjour removed: \(String(describing: endpoint))")
            @unknown default: break
            }
        }
        logger.info("Advertising Bonjour service '\(serviceName)' as \(AirPDFConstants.bonjourServiceType)")
    }
}
#endif
