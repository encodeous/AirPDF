#if os(macOS)
import SwiftUI
import Combine
import UniformTypeIdentifiers

struct MacContentView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        NavigationSplitView {
            List(appModel.sessions, selection: $appModel.selectedSessionID) { session in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.fileName).font(.headline)
                        Text("\(session.pageCount) pages").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        appModel.close(session: session)
                    } label: {
                        Image(systemName: session.hasUnsavedChanges ? "circle.fill" : "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Documents")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    ServerStatusView(server: appModel.server, onStart: { appModel.startServer() })
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let err = appModel.lastError {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        } detail: {
            detailView
        }
        .fileImporter(isPresented: $appModel.showOpenPanel, allowedContentTypes: [.pdf], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { appModel.openPDFs(at: urls) }
        }
        .alert("File Changed on Disk",
               isPresented: Binding(
                   get: { appModel.fileConflictSession != nil },
                   set: { if !$0 { appModel.fileConflictSession = nil } }
               ),
               presenting: appModel.fileConflictSession) { session in
            Button("Reload from Disk", role: .destructive) { appModel.reloadFromDisk(session: session) }
            Button("Keep In-Memory Version") { appModel.keepInMemory(session: session) }
        } message: { session in
            Text("\"\(session.fileName)\" was modified by another application. Reload from disk or keep your unsaved changes?")
        }
        .alert("Unsaved Changes",
               isPresented: Binding(
                   get: { appModel.closeConfirmSession != nil },
                   set: { if !$0 { appModel.closeConfirmSession = nil } }
               ),
               presenting: appModel.closeConfirmSession) { session in
            Button("Close Without Saving", role: .destructive) { appModel.forceClose(session: session) }
            Button("Cancel", role: .cancel) { appModel.closeConfirmSession = nil }
        } message: { session in
            Text("\"\(session.fileName)\" has unsaved changes. Close anyway?")
        }
        .onAppear { appModel.startServer() }
        .onReceive(NotificationCenter.default.publisher(for: .openPDFURLs)) { note in
            if let urls = note.object as? [URL] { appModel.openPDFs(at: urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else { return false }
            appModel.openPDFs(at: pdfs)
            return true
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let id = appModel.selectedSessionID,
           let session = appModel.sessions.first(where: { $0.id == id }) {
            MacPDFView(document: session.pdfDocument, session: session)
        } else {
            ContentUnavailableView("No Document Selected", systemImage: "doc.fill",
                                   description: Text("Open a PDF to get started."))
        }
    }
}

private struct ConnectedDotButton: View {
    let sid: String
    let peerFingerprint: String
    let ownFingerprint: String
    let onDisconnect: () -> Void
    @State private var showPopover = false

    var body: some View {
        Button { showPopover.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text(peerFingerprint).font(.caption).foregroundStyle(.secondary).monospaced()
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("iPad connected").bold()
                Divider()
                Label("Mac: \(ownFingerprint)", systemImage: "desktopcomputer").font(.caption).monospaced()
                Label("iPad: \(peerFingerprint)", systemImage: "ipad").font(.caption).monospaced()
                Text("Session: \(sid.prefix(8))…").font(.caption).foregroundStyle(.secondary)
                Divider()
                Button("Disconnect", role: .destructive, action: onDisconnect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding()
        }
    }
}

private struct ServerStatusView: View {
    @ObservedObject var server: QuicServer
    var onStart: () -> Void

    var body: some View {
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
                Text("Port: \(String(port))")
            }
        case .clientConnected(let sid, let fingerprint):
            ConnectedDotButton(sid: sid, peerFingerprint: fingerprint,
                               ownFingerprint: server.ownFingerprint,
                               onDisconnect: { server.disconnectClient() })
        }
    }
}
#endif
