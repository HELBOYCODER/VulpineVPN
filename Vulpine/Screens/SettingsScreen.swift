import SwiftUI

struct DohProvider: Identifiable, Hashable {
    let id: String
    let label: String
}

let dohProviders = [
    DohProvider(id: "auto", label: "Automatic"),
    DohProvider(id: "cloudflare", label: "Cloudflare (1.1.1.1)"),
    DohProvider(id: "quad9", label: "Quad9"),
]

struct SettingsScreen: View {
    @EnvironmentObject var state: AppState
    @State private var verifyExitLocation = true
    @State private var encryptedDns = false
    @State private var selectedDoh: DohProvider = dohProviders[0]
    @State private var showDohPicker = false
    @State private var customDnsEnabled = false
    @State private var customDnsServer = ""
    @State private var proxyOnlyMode = false
    @State private var upstreamProxyEnabled = false
    @State private var customEdgeAddress = ""
    @State private var showThemePicker = false

    var body: some View {
        List {
            Section("Appearance") {
                Button {
                    showThemePicker = true
                } label: {
                    HStack { Text("Theme"); Spacer(); Text(state.themeMode.label).foregroundStyle(.secondary) }
                }
            }
            Section {
                Toggle(isOn: $verifyExitLocation) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verify exit location")
                        Text("Check that the tunnel exits in the selected country")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $encryptedDns) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Encrypted DNS")
                        Text(selectedDoh.label).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: encryptedDns) { if $0 { showDohPicker = true } }
                Toggle(isOn: $customDnsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use a custom DNS server")
                        Text("Send your apps' DNS queries to a server you choose")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if customDnsEnabled {
                    TextField("DNS server", text: $customDnsServer)
                        .keyboardType(.decimalPad)
                }
            } header: { Text("Connection") }

            Section {
                Toggle(isOn: $proxyOnlyMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Proxy-only mode")
                        Text("Run only the local SOCKS5 proxy, without a VPN interface")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $upstreamProxyEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chain through upstream proxy")
                        Text("Connect to the VPN server through another proxy first")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Custom edge address"); Spacer()
                    Text(customEdgeAddress.isEmpty ? "Not set" : customEdgeAddress)
                        .foregroundStyle(.secondary)
                }
            } header: { Text("Advanced") }

            Section {
                NavigationLink { LogsScreen() } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("View logs")
                        Text("Recent connection activity").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                NavigationLink { AccountScreen() } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Manage account")
                        Text("Subscription status and data usage").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack { Text("Version"); Spacer(); Text("1.0.0").foregroundStyle(.secondary) }
            } header: { Text("About") }

            Section {
                Button(role: .destructive) {
                    state.email = nil
                } label: {
                    Text("Sign out").frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDohPicker) { DohPickerSheet(selected: $selectedDoh) }
        .confirmationDialog("Theme", isPresented: $showThemePicker, titleVisibility: .visible) {
            ForEach(ThemeMode.allCases) { mode in
                Button(mode.label) { state.setTheme(mode) }
            }
        }
    }
}

struct DohPickerSheet: View {
    @Binding var selected: DohProvider
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(dohProviders) { provider in
                Button {
                    selected = provider
                    dismiss()
                } label: {
                    HStack {
                        Text(provider.label)
                        Spacer()
                        if provider == selected { Image(systemName: "checkmark") }
                    }
                }
            }
            .navigationTitle("Encrypted DNS")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
