import SwiftUI
import AppKit
import Charts
import StationCore

enum Pane: String, CaseIterable, Identifiable {
    case overview, findings, agent, playground, mcp, tabs, activity, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Cockpit"
        case .findings: "Findings & Charts"
        case .agent: "Auto-Jobs"
        case .playground: "Workbench"
        case .mcp: "MCP Hub"
        case .tabs: "Browser Tabs"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .findings: "chart.bar.doc.horizontal"
        case .agent: "clock.badge.checkmark"
        case .playground: "slider.horizontal.below.rectangle"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .tabs: "macwindow.on.rectangle"
        case .activity: "waveform.path.ecg.rectangle"
        case .settings: "gearshape"
        }
    }
}

struct MainWindow: View {
    @ObservedObject var store: StationStore
    @ObservedObject private var daemon = DaemonProcessManager.shared
    @ObservedObject private var findings = FindingsStore.shared
    @AppStorage("pane") private var pane: Pane = .overview
    @State private var findingsCategory: FindingCategory = .all

    private var openPageCount: Int {
        store.tabs.filter { $0.type == "page" }.count
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { pane }, set: { pane = $0 ?? pane })) {
                Section("Automation & Data") {
                    row(.overview)
                    badgeRow(.findings, count: findings.items.count)
                    row(.agent)
                }
                Section("Browser & Agents") {
                    row(.playground)
                    row(.mcp)
                    badgeRow(.tabs, count: openPageCount)
                }
                Section("System") {
                    row(.activity)
                    row(.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 204, ideal: 224, max: 270)
            .safeAreaInset(edge: .bottom, spacing: 0) { connectionFooter }
        } detail: {
            detail
                .navigationTitle(pane.title)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if store.connectionStatus != .offline {
                            targetMenu
                            Button {
                                Task { await store.reloadActiveTab() }
                            } label: {
                                Label("Reload Tab", systemImage: "arrow.clockwise")
                            }
                            .help("Reload \(store.targetSummaryLabel)")
                            .disabled(store.token == nil)
                        } else {
                            Button {
                                Task {
                                    _ = await daemon.startOrRestartDaemon()
                                    await store.refreshNow()
                                }
                            } label: {
                                Label("Start Daemon", systemImage: "play.fill")
                            }
                            .disabled(daemon.isLaunching)
                        }
                    }
                }
        }
        .frame(minWidth: 980, minHeight: 620)
        .onAppear { store.setObserved(true) }
        .onDisappear { store.setObserved(false) }
    }

    private var targetMenu: some View {
        Menu {
            Section("Session Target") {
                ForEach(SessionTarget.ordered, id: \.self) { session in
                    Button {
                        store.switchSession(session)
                    } label: {
                        HStack {
                            Label(session.displayName, systemImage: session.iconName)
                            if store.pinnedTargetId == nil && store.activeSession == session {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            let pages = store.tabs.filter { $0.type == "page" }
            if !pages.isEmpty {
                Section("Pin Specific Open Tab") {
                    ForEach(pages) { tab in
                        Button {
                            store.pinTab(tab.id)
                        } label: {
                            HStack {
                                Text(tab.title.isEmpty ? tab.url : String(tab.title.prefix(38)))
                                if store.pinnedTargetId == tab.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Label(store.targetSummaryLabel, systemImage: store.pinnedTargetId != nil ? "pin.fill" : store.activeSession.iconName)
        }
        .help("Choose which browser tab or session receives Workbench commands")
    }

    private func row(_ p: Pane) -> some View {
        Label(p.title, systemImage: p.symbol).tag(p)
    }

    private func badgeRow(_ p: Pane, count: Int) -> some View {
        HStack {
            Label(p.title, systemImage: p.symbol)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(.secondary)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
        }
        .tag(p)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .overview:
            OverviewView(store: store, pane: $pane, findingsCategory: $findingsCategory)
        case .findings:
            FindingsView(store: store, selectedCategory: $findingsCategory)
        case .agent:
            AgentView { targetCategory in
                findingsCategory = targetCategory
                pane = .findings
            }
        case .playground:
            PlaygroundView(store: store)
        case .mcp:
            MCPHubView(store: store)
        case .tabs:
            TabsView(store: store, pane: $pane)
        case .activity:
            ActivityView(store: store)
        case .settings:
            SettingsView(store: store)
        }
    }

    private var connectionFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                StatusDot(status: store.connectionStatus)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(store.connectionStatus.label)
                            .font(.callout.weight(.medium))
                        if let v = store.daemonVersion {
                            Text("v\(v)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(store.connectionStatus == .offline
                         ? "127.0.0.1:19826 stopped"
                         : String(format: "127.0.0.1:19826 · %.2f ms", store.latencyMs))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cockpit Overview

struct OverviewView: View {
    @ObservedObject var store: StationStore
    @ObservedObject private var daemon = DaemonProcessManager.shared
    @ObservedObject private var findings = FindingsStore.shared
    @Binding var pane: Pane
    @Binding var findingsCategory: FindingCategory
    @State private var quickAddress: String = ""
    @State private var showingScreenshotSheet = false

    private var onGemini: Bool { store.tabURL.contains("gemini.google.com") }

    var body: some View {
        if store.connectionStatus == .offline {
            OfflineView(store: store)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    notice
                    telemetryHero
                    findingsPulseStrip
                    HStack(alignment: .top, spacing: 16) {
                        browserStageCard
                        mcpAndHealthCard
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    recentStreamCard
                }
                .padding(20)
                .frame(maxWidth: 1060)
                .frame(maxWidth: .infinity)
            }
            .onAppear {
                if quickAddress.isEmpty { quickAddress = store.tabURL }
            }
            .onChange(of: store.tabURL) { _, newURL in
                quickAddress = newURL
            }
            .sheet(isPresented: $showingScreenshotSheet) {
                screenshotPreviewSheet
            }
        }
    }

    @ViewBuilder
    private var notice: some View {
        switch store.connectionStatus {
        case .unauthorized:
            banner("Access token missing. Generate a 0600 token in Settings so Station accepts requests.",
                   action: "Open Settings") { pane = .settings }
        case .degraded:
            banner("Station responds to pings, but browser status failed. Restart the daemon or open a browser tab.",
                   action: "Restart Daemon") {
                Task {
                    _ = await daemon.startOrRestartDaemon()
                    await store.refreshNow()
                }
            }
        default:
            EmptyView()
        }
    }

    private func banner(_ text: String, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action {
                Button(action, action: perform)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private var telemetryHero: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusDot(status: store.connectionStatus)
                    Text("Loopback CDP Engine")
                        .cardTitle()
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(String(format: "%.2f", store.latencyMs))
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("ms")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text(String(format: "min %.2f ms", store.minLatencyMs))
                    Text("·")
                    Text(String(format: "peak %.2f ms", store.maxLatencyMs))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Chart(Array(store.latencyHistory.enumerated()), id: \.offset) { sample in
                AreaMark(x: .value("Sample", sample.offset), y: .value("ms", sample.element))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(
                        colors: [Color.accentColor.opacity(0.24), Color.accentColor.opacity(0.01)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Sample", sample.offset), y: .value("ms", sample.element))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(Color.accentColor)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 68)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Loopback response latency over recent samples")

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        Task {
                            _ = await daemon.startOrRestartDaemon()
                            await store.refreshNow()
                        }
                    } label: {
                        Label("Restart", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(daemon.isLaunching)

                    Button(role: .destructive) {
                        Task {
                            await daemon.stopDaemon()
                            await store.refreshNow()
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
                Text("Profile: \(daemon.selectedProfile) · \(store.tabs.filter { $0.type == "page" }.count) open tabs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.09)))
    }

    private var findingsPulseStrip: some View {
        let housingCount = findings.items.filter { $0.category == .housing }.count
        let jobCount = findings.items.filter { $0.category == .jobs }.count
        let otherCount = findings.items.filter { $0.category != .housing && $0.category != .jobs }.count
        let dueFollowUps = findings.items.filter(\.needsFollowUp).count

        return HStack(spacing: 14) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-Job Findings & CRM")
                    .font(.subheadline.weight(.semibold))
                Text("\(housingCount) housing · \(jobCount) jobs · \(otherCount) leads & deals" + (dueFollowUps > 0 ? " · \(dueFollowUps) follow-up due" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Housing") {
                findingsCategory = .housing
                pane = .findings
            }
            .controlSize(.small)
            Button("Jobs") {
                findingsCategory = .jobs
                pane = .findings
            }
            .controlSize(.small)
            Button("Open Findings & Charts") {
                findingsCategory = .all
                pane = .findings
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var browserStageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Active browser stage").cardTitle()
                Spacer()
                if onGemini {
                    Label(store.isLoggedIn ? "Signed in" : "Signed out",
                          systemImage: store.isLoggedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.exclamationmark")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(store.isLoggedIn ? .green : .orange)
                }
            }

            Text(store.tabTitle.isEmpty ? "Untitled page" : store.tabTitle)
                .font(.title3.weight(.semibold))
                .lineLimit(2)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("https://…", text: $quickAddress)
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .onSubmit {
                        Task { await store.navigateTarget(url: quickAddress) }
                    }
                if quickAddress != store.tabURL && !quickAddress.isEmpty {
                    Button("Go") {
                        Task { await store.navigateTarget(url: quickAddress) }
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))

            Spacer(minLength: 6)

            HStack(spacing: 8) {
                Button {
                    pane = .playground
                    Task { await store.captureSnapshot() }
                } label: {
                    Label("Inspect @eN Snapshot", systemImage: "viewfinder")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task {
                        await store.captureVisualPreview()
                        showingScreenshotSheet = true
                    }
                } label: {
                    Label("Preview", systemImage: "camera")
                }

                CopyButton(text: store.tabURL, title: "Copy URL")
                Spacer()
                Button("All Tabs") { pane = .tabs }
                    .buttonStyle(.link)
            }
        }
        .card()
    }

    private var mcpAndHealthCard: some View {
        let installedCount = MCPClientID.allCases.filter { MCPConfigurator.isInstalled(for: $0) }.count
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("System & MCP readiness").cardTitle()
                Spacer()
                Button("Configure MCP") { pane = .mcp }
                    .buttonStyle(.link)
                    .font(.callout)
            }

            healthRow(
                ok: store.doctorReport?.browser?.connected ?? (store.connectionStatus == .online),
                title: "Chrome DevTools Socket",
                detail: store.doctorReport?.browser?.product ?? "Persistent WebSocket active"
            )
            healthRow(
                ok: store.token != nil,
                title: "Local Token Guard (0600)",
                detail: store.token?.masked ?? "Missing ~/.flossi/station.token"
            )
            healthRow(
                ok: true,
                title: "Native Rust MCP Server",
                detail: "\(MCPConfigurator.tools.count) tools · \(installedCount)/\(MCPClientID.allCases.count) AI clients linked"
            )
            healthRow(
                ok: (store.doctorReport?.cdp?.mainSocketHealthy ?? true),
                title: "Secondary Tab Connection Pool",
                detail: "\(store.doctorReport?.cdp?.pooledSecondarySockets ?? 0) pooled background socket(s)"
            )

            Spacer(minLength: 4)
            HStack {
                Button("Run Doctor Check") {
                    Task { await store.refreshDoctorNow() }
                }
                .controlSize(.small)
                Spacer()
                Text(store.daemonArch ?? "rust-native")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .card()
    }

    private func healthRow(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var recentStreamCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent RPC stream").cardTitle()
                Spacer()
                if !store.rpcLogs.isEmpty {
                    Button("View Full Log") { pane = .activity }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }

            if store.rpcLogs.isEmpty {
                Text("Commands executed from Workbench, Tabs, or Auto-Jobs appear here with sub-millisecond timing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(store.rpcLogs.prefix(5)) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(entry.isSuccess ? Color.green : Color.red)
                        Text(entry.action)
                            .font(.callout.monospaced().weight(.medium))
                            .frame(width: 120, alignment: .leading)
                        Text(entry.payloadSummary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        LatencyBadge(ms: entry.latencyMs)
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .card()
    }

    private var screenshotPreviewSheet: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.tabTitle.isEmpty ? "Viewport Preview" : store.tabTitle)
                        .font(.headline)
                    Text(store.tabURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Refresh") { Task { await store.captureVisualPreview() } }
                Button("Done") { showingScreenshotSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            Divider()
            if store.isLoadingScreenshot {
                ProgressView("Capturing viewport over CDP…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let b64 = store.latestScreenshotBase64,
                      let data = Data(base64Encoded: b64),
                      let nsImg = NSImage(data: data) {
                Image(nsImage: nsImg)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
            } else {
                ContentUnavailableView("No screenshot available", systemImage: "photo")
            }
        }
        .padding(18)
        .frame(width: 780, height: 560)
    }
}
