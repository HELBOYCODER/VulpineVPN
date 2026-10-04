import SwiftUI

struct ServerListScreen: View {
    @EnvironmentObject var state: AppState
    @State private var errorMessage: String?

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
                                if let ping = city.pingMs { Text("\(ping) ms").foregroundStyle(.secondary) }
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
    }
}
