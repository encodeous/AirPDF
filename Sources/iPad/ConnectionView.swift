#if os(iOS)
import SwiftUI

struct ConnectionView: View {
    @StateObject private var vm = ConnectionViewModel()

    var body: some View {
        NavigationStack {
            Group {
                switch vm.client.state {
                case .disconnected, .failed:
                    hostListView
                case .connecting, .handshaking:
                    connectingView
                case .connected:
                    PDFTabView(store: vm.documentStore)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Label("Mac: \(vm.client.sessionFingerprint)", systemImage: "desktopcomputer")
                                    Label("iPad: \(vm.client.ownFingerprint)", systemImage: "ipad")
                                }
                                .font(.caption2).monospaced().foregroundStyle(.secondary)
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Disconnect", role: .destructive) { vm.disconnect() }
                            }
                        }
                }
            }
            .navigationTitle("AirPDF")
        }
    }

    private var hostListView: some View {
        HostListView(browser: vm.browser, onConnect: vm.connect, onConnectManual: vm.connectManual,
                     failureReason: { if case .failed(let r) = vm.client.state { return r }; return nil }())
    }

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(vm.client.state == .connecting ? "Connecting…" : "Handshaking…")
                .foregroundStyle(.secondary)
            Button("Cancel") { vm.disconnect() }
                .buttonStyle(.bordered)
        }
    }
}

private struct HostListView: View {
    @ObservedObject var browser: BonjourBrowser
    let onConnect: (BonjourBrowser.DiscoveredHost) -> Void
    let onConnectManual: (String, UInt16) -> Void
    let failureReason: String?

    @State private var manualHost = ""
    @State private var manualPort = "\(AirPDFConstants.serverPort)"
    @State private var showManual = false

    var body: some View {
        List {
            Section("Available Macs") {
                if browser.hosts.isEmpty {
                    Text("Searching…").foregroundStyle(.secondary).listRowBackground(Color.clear)
                } else {
                    ForEach(browser.hosts) { host in
                        Button { onConnect(host) } label: {
                            Label(host.name, systemImage: "desktopcomputer")
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
                        let port = UInt16(manualPort) ?? AirPDFConstants.serverPort
                        onConnectManual(manualHost, port)
                    }
                    .disabled(manualHost.isEmpty)
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
