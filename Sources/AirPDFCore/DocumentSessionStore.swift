import Foundation

public final class DocumentSessionStore {
    private var sessionsByID: [UUID: DocumentSession]
    private var order: [UUID]

    public init(
        sessionsByID: [UUID: DocumentSession] = [:],
        order: [UUID] = []
    ) {
        self.sessionsByID = sessionsByID
        self.order = order.filter { sessionsByID[$0] != nil }
    }

    public var sessions: [DocumentSession] {
        order.compactMap { sessionsByID[$0] }
    }

    public func upsert(_ session: DocumentSession) {
        if sessionsByID[session.id] == nil {
            order.append(session.id)
        }
        sessionsByID[session.id] = session
    }

    @discardableResult
    public func remove(id: UUID) -> DocumentSession? {
        let removed = sessionsByID.removeValue(forKey: id)
        order.removeAll { $0 == id }
        return removed
    }

    public func clear() {
        sessionsByID.removeAll()
        order.removeAll()
    }
}
