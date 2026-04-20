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

    @discardableResult
    func openPDF(at url: URL) -> Bool {
        guard let document = PDFDocument(url: url) else {
            lastError = "Unable to open \(url.lastPathComponent)."
            return false
        }

        let session = DocumentSession(
            fileName: url.lastPathComponent,
            fileURL: url,
            pageCount: document.pageCount
        )
        store.upsert(session)
        sessions = store.sessions
        selectedSessionID = session.id
        return true
    }

    func openPDFs(at urls: [URL]) {
        var firstError: String?
        for url in urls {
            if !openPDF(at: url), firstError == nil {
                firstError = lastError
            }
        }
        lastError = firstError
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
