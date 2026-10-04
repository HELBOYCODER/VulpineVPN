import SwiftUI

struct LogsScreen: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if state.logs.isEmpty {
                ContentUnavailableView("No log entries yet", systemImage: "doc.text")
            } else {
                List(state.logs) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.level).font(.caption.bold()).foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(entry.message).font(.subheadline)
                    }
                }
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(content: { () -> some ToolbarContent in
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = state.exportLogs()
                } label: { Image(systemName: "doc.on.doc") }
                Button(role: .destructive) {
                    state.logs.removeAll()
                } label: { Image(systemName: "trash") }
            }
        })
    }
}
