import SwiftUI
import StationCore

struct ActivityView: View {
    @ObservedObject var store: StationStore
    @State private var selection: RPCLogEntry.ID?
    @State private var failuresOnly = false
    @State private var query = ""

    private var entries: [RPCLogEntry] {
        store.rpcLogs.filter { entry in
            (!failuresOnly || !entry.isSuccess)
                && (query.isEmpty
                    || entry.action.localizedCaseInsensitiveContains(query)
                    || entry.session.localizedCaseInsensitiveContains(query)
                    || entry.payloadSummary.localizedCaseInsensitiveContains(query)
                    || entry.responseSummary.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        Group {
            if store.rpcLogs.isEmpty {
                ContentUnavailableView("No RPC activity yet", systemImage: "waveform.path.ecg.rectangle",
                                       description: Text("Requests sent to Station appear here with sub-millisecond timing."))
            } else {
                VSplitView {
                    table
                        .frame(minHeight: 220)
                    if let entry = store.rpcLogs.first(where: { $0.id == selection }) {
                        detail(entry)
                            .frame(minHeight: 170, idealHeight: 230)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Filter action, target, or payload")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $failuresOnly) {
                    Label("Failures Only", systemImage: "exclamationmark.triangle")
                }
                .help("Show only failed requests")

                Button {
                    selection = nil
                    store.clearLogs()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(store.rpcLogs.isEmpty)
                .help("Clear in-memory RPC log")
            }
        }
    }

    private var table: some View {
        Table(entries, selection: $selection) {
            TableColumn("") { entry in
                Image(systemName: entry.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(entry.isSuccess ? Color.green : Color.red)
                    .accessibilityLabel(entry.isSuccess ? "Succeeded" : "Failed")
            }
            .width(20)
            TableColumn("Time") { entry in
                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                    .monospacedDigit()
            }
            .width(min: 72, ideal: 86, max: 110)
            TableColumn("Action") { entry in
                Text(entry.action)
                    .font(.callout.monospaced().weight(.medium))
            }
            .width(min: 95, ideal: 130)
            TableColumn("Target", value: \.session)
                .width(min: 70, ideal: 110)
            TableColumn("Latency") { entry in
                LatencyBadge(ms: entry.latencyMs)
            }
            .width(min: 72, ideal: 88, max: 110)
            TableColumn("Response") { entry in
                Text(entry.responseSummary)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ entry: RPCLogEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(entry.action)
                        .font(.headline.monospaced())
                    LatencyBadge(ms: entry.latencyMs)
                    Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    CopyButton(text: "Request:\n\(entry.payloadSummary)\n\nResponse:\n\(entry.responseSummary)")
                }
                block("Request", entry.payloadSummary)
                block("Response", entry.responseSummary)
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).cardTitle()
            Text(text.isEmpty ? "Empty" : text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
