import SwiftUI
import AppKit
import StationCore

struct TabsView: View {
    @ObservedObject var store: StationStore
    @Binding var pane: Pane
    @State private var address = ""
    @State private var openInBackground = true
    @State private var searchQuery = ""

    private let quickBookmarks: [(String, String, String)] = [
        ("LinkedIn Jobs", "https://www.linkedin.com/jobs", "briefcase"),
        ("Avito Rent", "https://www.avito.ma", "house"),
        ("Mubawab", "https://www.mubawab.ma", "building.2"),
        ("GitHub", "https://github.com", "chevron.left.forwardslash.chevron.right"),
        ("Reddit", "https://www.reddit.com", "bubble.left.and.text.bubble.right"),
        ("Gemini", "https://gemini.google.com/app", "sparkles"),
    ]

    private var filteredPages: [ChromeTargetDTO] {
        let pages = store.tabs.filter { $0.type == "page" }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return pages }
        return pages.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.url.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        if store.connectionStatus == .offline {
            OfflineView(store: store)
        } else {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Enter URL to open in Chrome…", text: $address)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { open(address) }

                        Toggle("Background", isOn: $openInBackground)
                            .toggleStyle(.checkbox)
                            .help("Open without stealing focus from your active window")

                        Button("Open Tab") { open(address) }
                            .buttonStyle(.borderedProminent)
                            .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    HStack(spacing: 6) {
                        Text("Quick launch:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(quickBookmarks, id: \.0) { item in
                            Button {
                                open(item.1)
                            } label: {
                                Label(item.0, systemImage: item.2)
                                    .font(.caption)
                            }
                            .controlSize(.small)
                        }
                        Spacer()
                        TextField("Filter open tabs…", text: $searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }
                }
                .padding(14)

                Divider()

                if filteredPages.isEmpty {
                    ContentUnavailableView(
                        searchQuery.isEmpty ? "No open tabs" : "No matching tabs",
                        systemImage: "macwindow",
                        description: Text("Pages open in Station's Chrome profile appear here.")
                    )
                } else {
                    List(filteredPages) { tab in
                        row(tab)
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    private func row(_ tab: ChromeTargetDTO) -> some View {
        let isMain = !store.tabURL.isEmpty && tab.url == store.tabURL
        let isPinned = store.pinnedTargetId == tab.id

        return HStack(spacing: 10) {
            Image(systemName: isPinned ? "pin.circle.fill" : "globe")
                .foregroundStyle(isPinned ? Color.accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tab.title.isEmpty ? "Untitled" : tab.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if isMain {
                        badge("Main", color: .accentColor)
                    }
                    if isPinned {
                        badge("Pinned", color: .purple)
                    }
                }
                Text(tab.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Button("Inspect") {
                store.pinTab(tab.id)
                pane = .playground
                Task { await store.captureSnapshot() }
            }
            .controlSize(.small)
            .help("Pin this tab in Workbench and capture its @eN interactive snapshot")

            Button("Focus") {
                Task { await store.activateTab(tab.id) }
            }
            .controlSize(.small)
            .help("Bring this tab to the front in Chrome")

            Button {
                Task { await store.closeTab(tab.id) }
            } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .controlSize(.small)
            .help(isMain ? "Main tab stays open while Station is running" : "Close this tab")
            .disabled(isMain)
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Inspect in Workbench") {
                store.pinTab(tab.id)
                pane = .playground
                Task { await store.captureSnapshot() }
            }
            Button("Bring to Front in Chrome") { Task { await store.activateTab(tab.id) } }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.url, forType: .string)
            }
            Divider()
            Button("Close Tab", role: .destructive) { Task { await store.closeTab(tab.id) } }
                .disabled(isMain)
        }
    }

    private func badge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func open(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url = text.contains("://") || text.hasPrefix("about:") ? text : "https://" + text
        address = ""
        Task { await store.openTab(url: url, background: openInBackground) }
    }
}
