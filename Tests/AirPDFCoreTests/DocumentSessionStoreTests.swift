import AirPDFCore
import Foundation
import Testing

struct DocumentSessionStoreTests {
    @Test
    func preservesInsertionOrder() {
        let store = DocumentSessionStore()
        let first = DocumentSession(fileName: "A.pdf", fileURL: URL(filePath: "/tmp/a.pdf"), pageCount: 1)
        let second = DocumentSession(fileName: "B.pdf", fileURL: URL(filePath: "/tmp/b.pdf"), pageCount: 2)

        store.upsert(first)
        store.upsert(second)

        #expect(store.sessions.map(\.id) == [first.id, second.id])
    }

    @Test
    func removeSessionUpdatesState() {
        let store = DocumentSessionStore()
        let first = DocumentSession(fileName: "A.pdf", fileURL: URL(filePath: "/tmp/a.pdf"), pageCount: 1)

        store.upsert(first)
        let removed = store.remove(id: first.id)

        #expect(removed == first)
        #expect(store.sessions.isEmpty)
    }

    @Test
    func upsertExistingSessionReplacesWithoutReordering() {
        let store = DocumentSessionStore()
        let id = UUID()
        let first = DocumentSession(id: id, fileName: "A.pdf", fileURL: URL(filePath: "/tmp/a.pdf"), pageCount: 1)
        let updated = DocumentSession(id: id, fileName: "A-updated.pdf", fileURL: URL(filePath: "/tmp/a2.pdf"), pageCount: 3)

        store.upsert(first)
        store.upsert(updated)

        #expect(store.sessions.count == 1)
        #expect(store.sessions.first == updated)
    }
}
