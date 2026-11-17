import SwiftUI
import AppKit
import StationCore

struct MCPHubView: View {
    @ObservedObject var store: StationStore
    @ObservedObject private var daemon = DaemonProcessManager.shared

    @State private var installedStates: [MCPClientID: Bool] = [:]
    @State private var statusBanner: (message: String, isError: Bool)?
    @State private var toolFilter: String = ""
    @State private var liveTestOutput: String = ""
    @State private var liveTestTitle: String = ""
    @State private var isTestingTool: Bool = false

    private var binaryPath: String { daemon.resolvedBinaryPath }

    private var filteredTools: [MCPToolSpec] {
        let q = toolFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return MCPConfigurator.tools }
        return MCPConfigurator.tools.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.category.localizedCaseInsensitiveContains(q)
                || $0.summary.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroBanner
                if let banner = statusBanner {
                    feedbackBanner(banner.message, isError: banner.isError)
                }
                clientsSection
                workflowPromptsSection
                toolsCatalogSection
            }
            .padding(20)
            .frame(maxWidth: 1060)
            .frame(maxWidth: .infinity)
        }
        .onAppear { refreshInstalledStates() }
        .sheet(isPresented: Binding(get: { !liveTestTitle.isEmpty }, set: { if !$0 { liveTestTitle = "" } })) {
            liveToolResultSheet
        }
    }

    // MARK: - Hero Banner

    private var heroBanner: some View {
        let cliCmd = MCPConfigurator.claudeCodeCLICommand(binaryPath: binaryPath)
        let rawJSON = MCPConfigurator.serverJSONSnippet(binaryPath: binaryPath, profileName: daemon.selectedProfile)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(Color.accentColor)
                        Text("Native Rust MCP Server")
                            .font(.title3.weight(.semibold))
                        Text("stdio · zero extensions · auto-start")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .foregroundStyle(Color.accentColor)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    Text("Connect Claude Code, Claude Desktop, Cursor, Windsurf, or Antigravity to your real authenticated Chrome profiles. With `--auto-start`, AI agents wake Station automatically on first tool call.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                CopyButton(text: rawJSON, title: "Copy mcpServers JSON")
            }

            HStack(spacing: 8) {
                Text(cliCmd)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))

                CopyButton(text: cliCmd, title: "Copy Claude CLI")
            }
        }
        .card()
    }

    private func feedbackBanner(_ text: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.green)
            Text(text)
                .font(.callout)
            Spacer()
            Button {
                statusBanner = nil
            } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(11)
        .background((isError ? Color.red : Color.green).opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: - 1-Click Client Configurators

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("One-click agent setup").cardTitle()
                Spacer()
                Text("Safely merges \"station\" into mcpServers without touching your other MCP tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(MCPClientID.allCases) { client in
                    clientCard(client)
                }
            }
        }
    }

    private func clientCard(_ client: MCPClientID) -> some View {
        let installed = installedStates[client] ?? false
        let cfgPath = client.configPath()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: client.iconName)
                    .font(.title3)
                    .frame(width: 26)
                    .foregroundStyle(installed ? Color.green : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(client.displayName)
                        .font(.headline)
                    Text(client.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(installed ? "Linked" : "Not linked")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .foregroundStyle(installed ? Color.green : .secondary)
                    .background((installed ? Color.green : Color.primary).opacity(0.1), in: Capsule())
            }

            HStack(spacing: 8) {
                Button(installed ? "Update Path" : "Connect \(client.displayName)") {
                    installClient(client)
                }
                .buttonStyle(.borderedProminent)
                .tint(installed ? .secondary : .accentColor)
                .controlSize(.small)
                .disabled(!daemon.binaryExists)

                if installed {
                    Button("Remove", role: .destructive) {
                        removeClient(client)
                    }
                    .controlSize(.small)
                }

                Spacer()

                Button {
                    let url = URL(fileURLWithPath: cfgPath)
                    if FileManager.default.fileExists(atPath: cfgPath) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
                    }
                } label: {
                    Label("Config File", systemImage: "folder")
                        .labelStyle(.iconOnly)
                }
                .controlSize(.small)
                .help(cfgPath)
            }
        }
        .card(padding: 14)
    }

    private func refreshInstalledStates() {
        var map: [MCPClientID: Bool] = [:]
        for c in MCPClientID.allCases {
            map[c] = MCPConfigurator.isInstalled(for: c)
        }
        installedStates = map
    }

    private func installClient(_ client: MCPClientID) {
        do {
            try MCPConfigurator.install(
                for: client,
                binaryPath: binaryPath,
                profileName: daemon.selectedProfile
            )
            refreshInstalledStates()
            statusBanner = ("Linked Station MCP in \(client.displayName) (\(client.configPath())). Restart \(client.displayName) if it is already open.", false)
        } catch {
            statusBanner = ("Could not update \(client.displayName): \(error.localizedDescription)", true)
        }
    }

    private func removeClient(_ client: MCPClientID) {
        do {
            try MCPConfigurator.uninstall(for: client)
            refreshInstalledStates()
            statusBanner = ("Removed Station from \(client.displayName).", false)
        } catch {
            statusBanner = ("Failed to update \(client.displayName): \(error.localizedDescription)", true)
        }
    }

    // MARK: - Built-in Workflow Prompts

    private var workflowPromptsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Built-in MCP workflow prompts").cardTitle()
            HStack(alignment: .top, spacing: 12) {
                ForEach(MCPConfigurator.prompts) { prompt in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("/\(prompt.name)")
                                .font(.callout.monospaced().weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                            CopyButton(text: prompt.name, title: "Copy")
                                .controlSize(.mini)
                        }
                        Text(prompt.title)
                            .font(.subheadline.weight(.semibold))
                        Text(prompt.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .card(padding: 13)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 11 MCP Tools Explorer & Live Tester

    private var toolsCatalogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Available MCP tools (\(MCPConfigurator.tools.count))").cardTitle()
                Spacer()
                TextField("Filter tools…", text: $toolFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            VStack(spacing: 8) {
                ForEach(filteredTools) { tool in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(tool.name)
                                    .font(.callout.monospaced().weight(.semibold))
                                Text(tool.category)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .foregroundStyle(.secondary)
                                    .background(Color.primary.opacity(0.07), in: Capsule())
                                if tool.readOnly {
                                    Text("read-only")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            Text(tool.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        if canLiveTest(tool.name) && store.connectionStatus != .offline {
                            Button("Test Live") {
                                runLiveToolTest(tool.name)
                            }
                            .controlSize(.small)
                            .disabled(isTestingTool)
                        }

                        CopyButton(text: tool.exampleArgsJSON, title: "Args")
                            .controlSize(.small)
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.07)))
                }
            }
        }
    }

    private func canLiveTest(_ name: String) -> Bool {
        ["station_snapshot", "station_read", "station_doctor", "station_status"].contains(name)
    }

    private func runLiveToolTest(_ name: String) {
        isTestingTool = true
        liveTestTitle = name
        liveTestOutput = "Running \(name) against 127.0.0.1:19826…"

        Task {
            defer { isTestingTool = false }
            switch name {
            case "station_snapshot":
                await store.captureSnapshot()
                liveTestOutput = store.latestSnapshot?.snapshotText ?? "No snapshot returned."
            case "station_read":
                await store.extractCleanMarkdown()
                if let d = store.latestRead {
                    liveTestOutput = "# \(d.title)\nURL: \(d.url)\nToken reduction: -\(String(format: "%.1f", d.tokenSavingsPct))% (~\(d.estimatedTokens) tokens)\n\n---\n\n\(d.markdown)"
                } else {
                    liveTestOutput = "No Markdown returned."
                }
            case "station_doctor":
                await store.refreshDoctorNow()
                if let doc = store.doctorReport,
                   let data = try? JSONEncoder().encode(doc),
                   let obj = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                   let str = String(data: pretty, encoding: .utf8) {
                    liveTestOutput = str
                } else {
                    liveTestOutput = "Doctor report unavailable."
                }
            case "station_status":
                await store.refreshNow()
                liveTestOutput = "Title: \(store.tabTitle)\nURL: \(store.tabURL)\nLatency: \(String(format: "%.2f ms", store.latencyMs))"
            default:
                break
            }
        }
    }

    private var liveToolResultSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MCP Output Preview · \(liveTestTitle)")
                    .font(.headline.monospaced())
                Spacer()
                CopyButton(text: liveTestOutput)
                Button("Close") { liveTestTitle = "" }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            ScrollView {
                Text(liveTestOutput)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(18)
        .frame(width: 720, height: 500)
    }
}
