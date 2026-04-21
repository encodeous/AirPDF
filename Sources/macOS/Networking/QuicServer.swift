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
        case clientConnected(sessionId: String)
    }

    @Published private(set) var state: State = .stopped

    private var listener: NWListener?
    private var activeClient: ClientConnection?
    private let queue = DispatchQueue(label: "dev.airpdf.mac.quic", qos: .userInitiated)
    private let logger = Logger(subsystem: "dev.airpdf.mac", category: "QuicServer")

    // Injected by AppModel so the server can push PdfData on reconnect
    var onClientConnected: ((ClientConnection) -> Void)?
    var onClientDisconnected: (() -> Void)?

    func start() throws {
        guard state == .stopped else { return }

        let tlsOptions = NWProtocolTLS.Options()
        let identity = try TLSIdentity.selfSigned()
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            identity.secIdentity
        )
        sec_protocol_options_set_min_tls_protocol_version(
            tlsOptions.securityProtocolOptions,
            .TLSv12
        )

        let quicOptions = NWProtocolQUIC.Options(alpn: ["airpdf"])
        quicOptions.direction = .bidirectional

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

    // MARK: - Incoming connection

    private func handleIncoming(_ conn: NWConnection) {
        if activeClient != nil {
            // Single-client enforcement: reject immediately
            let client = ClientConnection(connection: conn, queue: queue)
            client.sendError(.clientAlreadyConnected, message: "A client is already connected.")
            client.cancel()
            logger.warning("Rejected second client connection")
            return
        }
        let client = ClientConnection(connection: conn, queue: queue)
        activeClient = client
        client.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.activeClient = nil
                self?.state = .running(port: AirPDFConstants.serverPort)
                self?.onClientDisconnected?()
            }
        }
        client.onSessionEstablished = { [weak self] sessionId in
            Task { @MainActor in
                self?.state = .clientConnected(sessionId: sessionId)
                self?.onClientConnected?(client)
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
