import SwiftUI

struct AccountScreen: View {
    @EnvironmentObject var state: AppState
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Firefox Account").font(.headline)
                    Text(state.email ?? "—").font(.subheadline)
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                    Button("Retry") { refresh() }
                }
            } else {
                Section("Subscription") {
                    accountRow(label: "Status", value: "Active")
                    accountRow(label: "Data used", value: "—")
                    accountRow(label: "Devices", value: "1")
                }
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        Task {
            do {
                _ = try await GuardianClient().fetchUserInfo(endpoint: GUARDIAN_ENDPOINT_DEFAULT, accessToken: "")
                await MainActor.run { errorMessage = nil }
            } catch {
                await MainActor.run { errorMessage = "Could not load account: \(error)" }
            }
        }
    }

    private func accountRow(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }
}
