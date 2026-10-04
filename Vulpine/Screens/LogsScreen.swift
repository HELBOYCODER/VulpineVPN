import SwiftUI

struct LogsScreen: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if state.logs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No log entries yet").foregroundStyle(.secondary)
                }
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
        .modifier(LogsToolbarModifier())
    }
}


/// iOS 16-safe toolbar for LogsScreen (SDK toolbar(content:) overloads are ambiguous here).
struct LogsToolbarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = AppState.shared.exportLogs()
                } label: { Image(systemName: "doc.on.doc") }
                Button(role: .destructive) {
                    AppState.shared.logs.removeAll()
                } label: { Image(systemName: "trash") }
            }
        }
    }
}
