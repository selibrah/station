import SwiftUI
import AppKit
import StationCore

// Native macOS semantic palette and typography: adapts cleanly to Light & Dark appearances,
// avoids decorative ALL-CAPS eyebrows, and uses tabular monospaced figures strictly for telemetry.

extension ConnectionStatus {
    var label: String {
        switch self {
        case .online: "Online"
        case .generating: "Generating"
        case .degraded: "Degraded"
        case .unauthorized: "Token missing"
        case .offline: "Offline"
        }
    }

    var color: Color {
        switch self {
        case .online: .green
        case .generating: .blue
        case .degraded, .unauthorized: .orange
        case .offline: .secondary
        }
    }
}

extension SessionTarget {
    static let ordered: [SessionTarget] = [.browser, .gemini, .linkedin, .github, .colab, .meta]
}

struct StatusDot: View {
    let status: ConnectionStatus
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .overlay {
                if status == .online || status == .generating {
                    Circle()
                        .strokeBorder(status.color.opacity(0.35), lineWidth: 2)
                        .frame(width: size + 4, height: size + 4)
                }
            }
            .accessibilityHidden(true)
    }
}

struct LatencyBadge: View {
    let ms: Double

    private var tint: Color {
        if ms <= 0 { return .secondary }
        if ms < 2.5 { return .green }
        if ms < 15.0 { return .blue }
        return .orange
    }

    var body: some View {
        Text(ms > 0 ? String(format: "%.2f ms", ms) : "–")
            .font(.caption.monospacedDigit().weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct RefBadge: View {
    let ref: String

    var body: some View {
        Text("@\(ref)")
            .font(.caption.monospaced().weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
    }
}

extension View {
    /// Clean native macOS container surface with hairline separator border.
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.08)))
    }

    /// Sentence-case section heading (replaces generic tracked-out uppercase labels).
    func cardTitle() -> some View {
        self
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct CopyButton: View {
    let text: String
    var title = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .disabled(text.isEmpty)
    }
}

/// Interactive empty state when the daemon is offline — lets the user launch Station in one click.
struct OfflineView: View {
    @ObservedObject var store: StationStore
    @ObservedObject private var daemon = DaemonProcessManager.shared

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("Station daemon is stopped")
                    .font(.title2.weight(.semibold))
                Text("Start the local Rust CDP engine to inspect tabs, run Auto-Jobs, or serve MCP tools.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            HStack(spacing: 10) {
                Picker("Profile", selection: $daemon.selectedProfile) {
                    ForEach(daemon.availableProfiles, id: \.self) { prof in
                        Text(prof).tag(prof)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                .help("Isolated Chrome profile under ~/.flossi/profiles/")

                Toggle("Multi-tab window", isOn: $daemon.standardWindow)
                    .toggleStyle(.checkbox)

                Button {
                    Task {
                        _ = await daemon.startOrRestartDaemon()
                        await store.refreshNow()
                    }
                } label: {
                    if daemon.isLaunching {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Starting…")
                        }
                    } else {
                        Label("Start Station", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(daemon.isLaunching || !daemon.binaryExists)
            }

            if let msg = daemon.lastMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !daemon.binaryExists {
                Text("Binary not found at \(daemon.resolvedBinaryPath). Run `cargo build --release` inside `daemon/`.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Full-width row that highlights on hover, for the menu bar panel.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    hovering && isEnabled
                        ? Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}
