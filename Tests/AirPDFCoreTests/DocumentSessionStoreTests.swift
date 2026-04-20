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
}
