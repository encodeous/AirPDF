#if os(macOS)
import Foundation

struct DocumentSession: Identifiable, Equatable, Sendable {
    let id: UUID          // local SwiftUI identity
    let documentId: String // AirPDF protocol document_id sent to iPad
    let fileName: String
    let fileURL: URL
    let pageCount: Int

    init(fileName: String, fileURL: URL, pageCount: Int) {
        self.id = UUID()
        self.documentId = UUID().uuidString
        self.fileName = fileName
        self.fileURL = fileURL
        self.pageCount = pageCount
    }
}
#endif
