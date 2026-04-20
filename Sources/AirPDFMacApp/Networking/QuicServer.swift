import Foundation
import Network
import os

final class QuicServer {
    enum State: Equatable {
        case stopped
        case running

        var label: String {
            switch self {
            case .stopped: "Stopped"
            case .running: "Running"
            }
        }
    }

    var onStateChange: ((State) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.airpdf.mac.quic-server")
    private let logger = Logger(subsystem: "dev.airpdf.mac", category: "quic-server")
    private let maxReceiveLength = 64 * 1024

    func start(port: UInt16) throws {
        guard listener == nil else { return }

        let options = NWProtocolQUIC.Options()
        let parameters = NWParameters(quic: options)
        parameters.allowLocalEndpointReuse = true

        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.configure(connection: connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onStateChange?(.running)
            case .failed, .cancelled:
                self?.onStateChange?(.stopped)
            default:
                break
            }
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        onStateChange?(.stopped)
    }

    private func configure(connection: NWConnection) {
        connection.stateUpdateHandler = { [logger] state in
            if case let .failed(error) = state {
                logger.error("Connection failed: \(String(describing: error))")
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxReceiveLength) { [weak self, logger] data, _, isComplete, error in
            if let data, !data.isEmpty {
                logger.debug("Received \(data.count) bytes")
            }

            if let error {
                logger.error("Receive failed: \(String(describing: error))")
            }

            if error == nil && !isComplete {
                self?.receive(on: connection)
                return
            }

            connection.cancel()
        }
    }
}
