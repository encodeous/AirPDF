#if os(iOS)
import SwiftUI
import PDFKit

struct PDFTabView: View {
    @ObservedObject var store: DocumentStore
    @State private var selectedId: String?

    var body: some View {
        if store.documents.isEmpty {
            ContentUnavailableView("Waiting for Documents", systemImage: "doc.fill",
                                   description: Text("Open a PDF on the Mac to get started."))
        } else {
            let docs = store.documents
            let sel = selectedId ?? docs[0].id
            VStack(spacing: 0) {
                if docs.count > 1 {
                    Picker("Document", selection: Binding(
                        get: { sel },
                        set: { selectedId = $0 }
                    )) {
                        ForEach(docs) { doc in
                            Text(doc.fileName).tag(doc.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    Divider()
                }
                if let doc = docs.first(where: { $0.id == sel }) ?? docs.first {
                    iPadPDFView(data: doc.pdfData)
                }
            }
            .onChange(of: store.documents) { _, newDocs in
                if let current = selectedId, !newDocs.contains(where: { $0.id == current }) {
                    selectedId = newDocs.first?.id
                }
            }
        }
    }
}

private struct iPadPDFView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {}
}
#endif
