import AirPDFCore
import Foundation
import PDFKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [DocumentSession] = []
    @Published private(set) var serverState: QuicServer.State = .stopped
    @Published var selectedSessionID: UUID?
    @Published var lastError: String?

    let quicServer: QuicServer
    private let store = DocumentSessionStore()

    init(quicServer: QuicServer = QuicServer()) {
        self.quicServer = quicServer
        self.quicServer.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.serverState = state
            }
        }
    }

    func openPDF(at url: URL) {
        guard let document = PDFDocument(url: url) else {
            lastError = "Unable to open \(url.lastPathComponent)."
            return
        }

        let session = DocumentSession(
            fileName: url.lastPathComponent,
            fileURL: url,
            pageCount: document.pageCount
        )
        store.upsert(session)
        sessions = store.sessions
        selectedSessionID = session.id
    }

    func closeSelectedPDF() {
        guard let selectedSessionID else { return }
        _ = store.remove(id: selectedSessionID)
        sessions = store.sessions
        self.selectedSessionID = sessions.last?.id
    }

    func startServer(port: UInt16 = 9443) {
        do {
            try quicServer.start(port: port)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopServer() {
        quicServer.stop()
    }
}
