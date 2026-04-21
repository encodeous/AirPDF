#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct MacContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showImporter = false

    var body: some View {
        NavigationSplitView {
            List(appModel.sessions, selection: $appModel.selectedSessionID) { session in
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.fileName).font(.headline)
                    Text("\(session.pageCount) pages").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Documents")
            .toolbar {
                ToolbarItem { Button("Open") { showImporter = true } }
                ToolbarItem {
                    Button("Close") { appModel.closeSelectedPDF() }
                        .disabled(appModel.selectedSessionID == nil)
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 12) {
                Text("AirPDF").font(.largeTitle.bold())
                serverStatusView
                if let err = appModel.lastError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
                Spacer()
            }
            .padding()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { appModel.openPDFs(at: urls) }
        }
        .onAppear { appModel.startServer() }
    }

    @ViewBuilder
    private var serverStatusView: some View {
        ServerStatusView(server: appModel.server, onStart: { appModel.startServer() })
    }
}

private struct ServerStatusView: View {
    @ObservedObject var server: QuicServer
    var onStart: () -> Void

    var body: some View {
        let _ = print("[UI] serverStatusView rendering, state=\(server.state)")
        switch server.state {
        case .stopped:
            HStack {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Server stopped")
                Button("Start", action: onStart).buttonStyle(.borderedProminent)
            }
        case .running(let port):
            HStack {
                Circle().fill(.orange).frame(width: 8, height: 8)
                Text("Listening on port \(port) — waiting for iPad")
            }
        case .clientConnected(let sid):
            HStack {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("iPad connected").bold()
                Text("(\(sid.prefix(8))…)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
