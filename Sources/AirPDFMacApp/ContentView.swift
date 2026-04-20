import AirPDFCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showImporter = false

    var body: some View {
        NavigationSplitView {
            List(appModel.sessions, selection: $appModel.selectedSessionID) { session in
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.fileName)
                        .font(.headline)
                    Text("\(session.pageCount) pages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Documents")
            .toolbar {
                ToolbarItemGroup {
                    Button("Open PDF") { showImporter = true }
                    Button("Close PDF") { appModel.closeSelectedPDF() }
                        .disabled(appModel.selectedSessionID == nil)
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                Text("AirPDF macOS Host")
                    .font(.largeTitle.bold())
                Text("Server: \(appModel.serverState.label)")
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Start QUIC Server") {
                        appModel.startServer()
                    }
                    .disabled(appModel.serverState == .running)

                    Button("Stop Server") {
                        appModel.stopServer()
                    }
                    .disabled(appModel.serverState == .stopped)
                }

                if let lastError = appModel.lastError {
                    Text(lastError)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                urls.forEach(appModel.openPDF(at:))
            case .failure(let error):
                appModel.lastError = error.localizedDescription
            }
        }
    }
}
