#if os(macOS)
import Foundation

final class DocumentSessionStore {
    private var sessionsByID: [UUID: DocumentSession] = [:]
    private var order: [UUID] = []

    var sessions: [DocumentSession] {
        order.compactMap { sessionsByID[$0] }
    }

    func upsert(_ session: DocumentSession) {
        if sessionsByID[session.id] == nil { order.append(session.id) }
        sessionsByID[session.id] = session
    }

    @discardableResult
    func remove(id: UUID) -> DocumentSession? {
        let removed = sessionsByID.removeValue(forKey: id)
        order.removeAll { $0 == id }
        return removed
    }
}
#endif
