import SwiftUI
import AppKit
import StationCore

struct SettingsView: View {
    @ObservedObject var store: StationStore
    @ObservedObject private var daemon = DaemonProcessManager.shared
    @ObservedObject private var autoLaunch = AutoLaunchManager.shared
    @State private var revealed = false
    @State private var confirmingRegenerate = false

    private var tokenPath: String {
        if let path = store.token?.path, !path.isEmpty { return path }
        return NSString(string: "~/.flossi/station.token").expandingTildeInPath
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Station binary") {
                    HStack(spacing: 8) {
                        Text(daemon.resolvedBinaryPath)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Image(systemName: daemon.binaryExists ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(daemon.binaryExists ? Color.green : Color.orange)
                    }
                }
                Picker("Launch profile", selection: $daemon.selectedProfile) {
                    ForEach(daemon.availableProfiles, id: \.self) { prof in
                        Text("~/.flossi/profiles/\(prof)").tag(prof)
                    }
                }
                Toggle("Open Chrome in standard multi-tab window", isOn: $daemon.standardWindow)
                TextField("Initial launch URL", text: $daemon.initialURL)
                    .font(.callout.monospaced())
            } header: {
                Text("Daemon & Browser Profile")
            } footer: {
                Text("Each profile keeps its own cookies and logins isolated on disk (e.g. separate `jobs` and `rent` profiles).")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent("Token") {
                    HStack(spacing: 8) {
                        Text(tokenText)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if let raw = store.token?.rawValue {
                            Button {
                                revealed.toggle()
                            } label: {
                                Label(revealed ? "Hide" : "Show", systemImage: revealed ? "eye.slash" : "eye")
                                    .labelStyle(.iconOnly)
                            }
                            .help(revealed ? "Hide the token" : "Show the token")
                            CopyButton(text: raw)
                        }
                    }
                }
                LabeledContent("File") {
                    HStack(spacing: 8) {
                        Text(tokenPath)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tokenPath)])
                        }
                        .disabled(store.token == nil)
                    }
                }
                if let loaded = store.token?.loadedAt {
                    LabeledContent("Loaded", value: loaded.formatted(date: .abbreviated, time: .shortened))
                }
                HStack {
                    Spacer()
                    Button(store.token == nil ? "Create Token" : "Regenerate…") {
                        if store.token == nil { store.generateNewToken() } else { confirmingRegenerate = true }
                    }
                }
            } header: {
                Text("Access Token (POSIX 0600)")
            } footer: {
                Text("Every request to Station carries this token in X-Station-Token. Station Studio watches the file via kqueue vnodes with zero polling.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Startup") {
                Toggle(isOn: Binding(get: { autoLaunch.isEnabled }, set: { _ in autoLaunch.toggle() })) {
                    Text("Open Station Studio at login")
                    Text(autoLaunch.statusMessage)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { autoLaunch.refresh() }
        .confirmationDialog("Regenerate the access token?", isPresented: $confirmingRegenerate) {
            Button("Regenerate", role: .destructive) { store.generateNewToken() }
        } message: {
            Text("Writes a fresh 256-bit token to disk. Restart the running daemon so it picks up the new token.")
        }
    }

    private var tokenText: String {
        guard let token = store.token, !token.rawValue.isEmpty else { return "None" }
        return revealed ? token.rawValue : token.masked
    }
}
