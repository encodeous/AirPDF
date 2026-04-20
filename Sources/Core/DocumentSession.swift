import Foundation

public struct DocumentSession: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let fileName: String
    public let fileURL: URL
    public let pageCount: Int

    public init(
        id: UUID = UUID(),
        fileName: String,
        fileURL: URL,
        pageCount: Int
    ) {
        self.id = id
        self.fileName = fileName
        self.fileURL = fileURL
        self.pageCount = pageCount
    }
}
