import SwiftUI

struct ServerListScreen: View {
    @EnvironmentObject var state: AppState
    @State private var errorMessage: String?
    @State private var pinging = false

    var body: some View {
        List {
            Section {
                Button {
                    state.selectedServer = nil
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recommended").font(.headline)
                        Text("Automatically chosen for the best performance")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            ForEach(state.countries) { country in
                Section(country.name) {
                    ForEach(country.cities) { city in
                        Button {
                            state.selectedServer = city
                        } label: {
                            HStack {
                                Text(city.city)
                                Spacer()
                                if let ping = city.pingMs {
                                    Text("\(ping) ms").foregroundStyle(.secondary)
                                }
                                if state.selectedServer?.id == city.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Choose location")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                pingServers()
            } label: {
                if pinging {
                    ProgressView()
                } else {
                    Label("Measure latency", systemImage: "gauge.with.needle")
                }
            }
        }
    }

    /// Measures TCP connect latency to each edge address (port of PingUtil).
    /// VpnServer.id currently holds the edge hostname.
    private func pingServers() {
        guard !pinging else { return }
        pinging = true
        Task {
            var updated: [VpnCountryUI] = []
            for country in state.countries {
                var cities: [VpnServer] = []
                for city in country.cities {
                    let latency = await ServerPinger.ping(host: city.id, port: 443)
                    cities.append(VpnServer(id: city.id, country: city.country,
                                            city: city.city, pingMs: latency))
                }
                updated.append(VpnCountryUI(id: country.id, name: country.name, cities: cities))
            }
            await MainActor.run {
                state.countries = updated
                pinging = false
                state.log("INFO", "Latency measured for \(state.countries.count) countries")
            }
        }
    }
}
