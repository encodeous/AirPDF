#if os(iOS)
import SwiftUI

struct ConnectionView: View {
    @StateObject private var vm = ConnectionViewModel()

    var body: some View {
        NavigationStack {
            ClientStateView(client: vm.client, vm: vm)
                .navigationTitle("AirPDF")
        }
    }
}

private struct ClientStateView: View {
    @ObservedObject var client: QuicClient
    let vm: ConnectionViewModel

    var body: some View {
        Group {
            switch client.state {
            case .disconnected, .failed:
                HostListView(browser: vm.browser, onConnect: vm.connect, onConnectManual: vm.connectManual,
                             failureReason: { if case .failed(let r) = client.state { return r }; return nil }())
            case .connecting, .handshaking:
                VStack(spacing: 16) {
                    ProgressView()
                    Text(client.state == .connecting ? "Connecting…" : "Handshaking…")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { vm.disconnect() }
                        .buttonStyle(.bordered)
                }
            case .connected(let sessionId):
                ConnectedSessionView(client: client, vm: vm, sessionId: sessionId)
            }
        }
    }
}

private struct ConnectedSessionView: View {
    @ObservedObject var client: QuicClient
    let vm: ConnectionViewModel
    let sessionId: String

    @State private var showConnectionInfo = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PDFTabView(store: vm.documentStore, onStrokeDelta: { vm.send($0) },
                       onVCReady: { [weak vm] vc in vm?.activeDrawingVC = vc })

            Button { showConnectionInfo.toggle() } label: {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.trailing, 16)
            .popover(isPresented: $showConnectionInfo, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Mac connected").bold()
                    Divider()
                    Label("Mac: \(client.sessionFingerprint)", systemImage: "desktopcomputer")
                        .font(.caption)
                        .monospaced()
                    Label("iPad: \(client.ownFingerprint)", systemImage: "ipad")
                        .font(.caption)
                        .monospaced()
                    Text("Session: \(sessionId.prefix(8))…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    Button("Disconnect", role: .destructive) {
                        showConnectionInfo = false
                        vm.disconnect()
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct HostListView: View {
    @ObservedObject var browser: BonjourBrowser
    let onConnect: (BonjourBrowser.DiscoveredHost) -> Void
    let onConnectManual: (String, UInt16) -> Void
    let failureReason: String?

    @State private var manualHost = ""
    @State private var manualPort = ""
    @State private var showManual = false

    var body: some View {
        List {
            Section("Available Macs") {
                if browser.hosts.isEmpty {
                    Text("Searching…").foregroundStyle(.secondary).listRowBackground(Color.clear)
                } else {
                    ForEach(browser.hosts) { host in
                        Button { onConnect(host) } label: {
                            let duplicateName = browser.hosts.filter { $0.name == host.name }.count > 1
                            if duplicateName, let port = host.port {
                                Label("\(host.name) :\(port)", systemImage: "desktopcomputer")
                            } else {
                                Label(host.name, systemImage: "desktopcomputer")
                            }
                        }
                    }
                }
            }
            Section {
                DisclosureGroup("Connect manually", isExpanded: $showManual) {
                    TextField("IP Address", text: $manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $manualPort).keyboardType(.numberPad)
                    Button("Connect") {
                        guard let port = UInt16(manualPort) else { return }
                        onConnectManual(manualHost, port)
                    }
                    .disabled(manualHost.isEmpty || UInt16(manualPort) == nil)
                }
            }
            if let reason = failureReason {
                Section {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
        }
    }
}
#endif
