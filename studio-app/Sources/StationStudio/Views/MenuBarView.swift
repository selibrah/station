import SwiftUI
import AppKit
import StationCore

struct MenuBarView: View {
    @ObservedObject var store: StationStore
    @ObservedObject private var daemon = DaemonProcessManager.shared
    @ObservedObject private var findings = FindingsStore.shared
    @ObservedObject private var autoLaunch = AutoLaunchManager.shared
    @Binding var selectedPane: Pane
    @Environment(\.openWindow) private var openWindow
    @State private var quickURL = ""
    @State private var copiedFeedback: String?

    private var offline: Bool { store.connectionStatus == .offline }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    StatusDot(status: store.connectionStatus)
                    Text(store.connectionStatus.label)
                        .font(.headline)
                    Spacer()
                    if !offline {
                        LatencyBadge(ms: store.latencyMs)
                    } else {
                        Button {
                            Task {
                                _ = await daemon.startOrRestartDaemon()
                                await store.refreshNow()
                            }
                        } label: {
                            Label(daemon.isLaunching ? "Starting…" : "Start", systemImage: "play.fill")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(daemon.isLaunching || !daemon.binaryExists)
                    }
                }

                if offline {
                    Text("Daemon stopped on 127.0.0.1:19826.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.tabTitle.isEmpty ? "Untitled" : store.tabTitle)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(store.tabURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let msg = copiedFeedback {
                    Text(msg)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if !offline {
                HStack(spacing: 6) {
                    TextField("Open URL in background…", text: $quickURL)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { openBackgroundURL() }
                    Button("Open") { openBackgroundURL() }
                        .controlSize(.small)
                        .disabled(quickURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            Divider()

            VStack(spacing: 1) {
                Button {
                    selectedPane = .overview
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open Cockpit", systemImage: "gauge.with.dots.needle.33percent")
                }

                Button {
                    selectedPane = .findings
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack {
                        Label("Findings & Charts", systemImage: "chart.bar.doc.horizontal")
                        Spacer()
                        if !findings.items.isEmpty {
                            Text("\(findings.items.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Button {
                    selectedPane = .playground
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Web Workbench", systemImage: "slider.horizontal.below.rectangle")
                }

                Button {
                    selectedPane = .mcp
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("MCP Agent Hub", systemImage: "point.3.connected.trianglepath.dotted")
                }

                Divider().padding(.vertical, 3)

                Button {
                    Task {
                        await store.extractCleanMarkdown()
                        if let md = store.latestRead?.markdown {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(md, forType: .string)
                            flash("Copied clean Markdown (-\(String(format: "%.0f", store.latestRead?.tokenSavingsPct ?? 0))% vs HTML)")
                        }
                    }
                } label: {
                    Label("Copy Tab as Clean Markdown", systemImage: "doc.plaintext")
                }
                .disabled(offline || store.token == nil)

                Button {
                    let cmd = MCPConfigurator.claudeCodeCLICommand(binaryPath: daemon.resolvedBinaryPath)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                    flash("Copied `claude mcp add station …`")
                } label: {
                    Label("Copy Claude MCP Command", systemImage: "terminal")
                }
            }
            .buttonStyle(MenuRowStyle())
            .padding(6)

            Divider()

            Toggle("Open at login", isOn: Binding(
                get: { autoLaunch.isEnabled },
                set: { _ in autoLaunch.toggle() }
            ))
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Text("Quit Station Studio")
                    Spacer()
                    Text("⌘Q").foregroundStyle(.secondary)
                }
            }
            .keyboardShortcut("q")
            .buttonStyle(MenuRowStyle())
            .padding(6)
        }
        .frame(width: 318)
        .onAppear {
            store.setObserved(true)
            findings.reload()
            autoLaunch.refresh()
        }
        .onDisappear { store.setObserved(false) }
    }

    private func openBackgroundURL() {
        let raw = quickURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let url = raw.contains("://") ? raw : "https://\(raw)"
        quickURL = ""
        Task {
            await store.openTab(url: url, background: true)
            flash("Opened background tab")
        }
    }

    private func flash(_ message: String) {
        copiedFeedback = message
        Task {
            try? await Task.sleep(for: .seconds(2.0))
            if copiedFeedback == message { copiedFeedback = nil }
        }
    }
}
