#if os(macOS)
import SwiftUI
import Combine
import UniformTypeIdentifiers

struct MacContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showImporter = false

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
                        Image(systemName: "xmark").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Documents")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    ServerStatusView(server: appModel.server, onStart: { appModel.startServer() })
                    if let err = appModel.lastError {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem { Button("Open") { showImporter = true } }
                ToolbarItem {
                    Button("Save") { appModel.saveSelectedPDF() }
                        .disabled(appModel.selectedSessionID == nil)
                }
                ToolbarItem {
                    Button("Undo") {
                        if let id = appModel.selectedSessionID,
                           let s = appModel.sessions.first(where: { $0.id == id }) {
                            s.undoManager.undo()
                            appModel.objectWillChange.send()
                        }
                    }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled({
                        guard let id = appModel.selectedSessionID,
                              let s = appModel.sessions.first(where: { $0.id == id })
                        else { return true }
                        return !s.undoManager.canUndo
                    }())
                }
                ToolbarItem {
                    Button("Redo") {
                        if let id = appModel.selectedSessionID,
                           let s = appModel.sessions.first(where: { $0.id == id }) {
                            s.undoManager.redo()
                            appModel.objectWillChange.send()
                        }
                    }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled({
                        guard let id = appModel.selectedSessionID,
                              let s = appModel.sessions.first(where: { $0.id == id })
                        else { return true }
                        return !s.undoManager.canRedo
                    }())
                }
            }
        } detail: {
            detailView
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { appModel.openPDFs(at: urls) }
        }
        .onAppear { appModel.startServer() }
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
