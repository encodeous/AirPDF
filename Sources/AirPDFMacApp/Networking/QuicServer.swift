import Foundation
import Network

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
        connection.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                print("Connection failed: \(error)")
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, isComplete, error in
            if error == nil && !isComplete {
                self.receive(on: connection)
            } else {
                connection.cancel()
            }
        }
    }
}
