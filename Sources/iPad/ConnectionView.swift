#if os(iOS)
import SwiftUI

struct ConnectionView: View {
    @StateObject private var vm = ConnectionViewModel()

    init() {}

    var body: some View {
        NavigationStack {
            Group {
                switch vm.client.state {
                case .disconnected, .failed:
                    hostListView
                case .connecting, .handshaking:
                    connectingView
                case .connected(let sid):
                    connectedView(sessionId: sid)
                }
            }
            .navigationTitle("AirPDF")
        }
    }

    // MARK: - Host list

    private var hostListView: some View {
        HostListView(browser: vm.browser, onConnect: vm.connect, onConnectManual: vm.connectManual,
                     failureReason: { if case .failed(let r) = vm.client.state { return r }; return nil }())
    }

    // MARK: - Connecting

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(vm.client.state == .connecting ? "Connecting…" : "Handshaking…")
                .foregroundStyle(.secondary)
            Button("Cancel") { vm.disconnect() }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Connected

    private func connectedView(sessionId: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Connected to Mac")
                .font(.title2.bold())
            Text("Session: \(sessionId.prefix(8))…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Disconnect") { vm.disconnect() }
                .buttonStyle(.bordered)
                .tint(.red)
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
                    Text("Searching…")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(browser.hosts) { host in
                        Button {
                            onConnect(host)
                        } label: {
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
                    TextField("Port", text: $manualPort)
                        .keyboardType(.numberPad)
                    Button("Connect") {
                        let port = UInt16(manualPort) ?? AirPDFConstants.serverPort
                        onConnectManual(manualHost, port)
                    }
                    .disabled(manualHost.isEmpty)
                }
            }

            if let reason = failureReason {
                Section {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
#endif
