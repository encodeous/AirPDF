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
        List {
            Section("Available Macs") {
                if vm.browser.hosts.isEmpty {
                    Text("Searching…")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(vm.browser.hosts) { host in
                        Button {
                            vm.connect(to: host)
                        } label: {
                            Label(host.name, systemImage: "desktopcomputer")
                        }
                    }
                }
            }

            if case .failed(let reason) = vm.client.state {
                Section {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .refreshable { /* Bonjour updates automatically */ }
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
#endif
