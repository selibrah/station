import SwiftUI
import AppKit
import StationCore

enum WorkbenchMode: String, CaseIterable, Identifiable {
    case snapshot = "Snapshot (@eN)"
    case reader   = "Clean Markdown"
    case eval     = "JS Console"
    case chat     = "Chat Prompt"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .snapshot: "viewfinder"
        case .reader:   "doc.plaintext"
        case .eval:     "curlybraces"
        case .chat:     "text.bubble"
        }
    }
}

struct PlaygroundView: View {
    @ObservedObject var store: StationStore
    @State private var mode: WorkbenchMode = .snapshot
    @State private var showVisualPane: Bool = false
    @State private var filterText: String = ""
    @State private var viewportOnly: Bool = false
    @State private var fillTargetRef: String?
    @State private var fillValue: String = ""
    @State private var customReadURL: String = ""
    @FocusState private var composing: Bool

    var body: some View {
        if store.connectionStatus == .offline {
            OfflineView(store: store)
        } else {
            VStack(spacing: 0) {
                headerBar
                Divider()
                HSplitView {
                    Group {
                        switch mode {
                        case .snapshot: snapshotModeView
                        case .reader:   readerModeView
                        case .eval:     evalModeView
                        case .chat:     chatModeView
                        }
                    }
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)

                    if showVisualPane {
                        visualPreviewSidebar
                            .frame(minWidth: 280, idealWidth: 340, maxWidth: 440)
                    }
                }
            }
        }
    }

    // MARK: - Top Workbench Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $mode) {
                ForEach(WorkbenchMode.allCases) { m in
                    Label(m.rawValue, systemImage: m.symbol).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 480)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: store.pinnedTargetId != nil ? "pin.fill" : "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(store.targetSummaryLabel)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: Capsule())

            Toggle(isOn: $showVisualPane) {
                Label("Live Preview", systemImage: "sidebar.right")
            }
            .toggleStyle(.button)
            .onChange(of: showVisualPane) { _, visible in
                if visible && store.latestScreenshotBase64 == nil {
                    Task { await store.captureVisualPreview() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 1. Interactive @eN Snapshot Mode

    private var filteredElements: [SnapshotElementDTO] {
        guard let elems = store.latestSnapshot?.elements else { return [] }
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return elems }
        return elems.filter {
            $0.ref.localizedCaseInsensitiveContains(q)
                || $0.label.localizedCaseInsensitiveContains(q)
                || $0.role.localizedCaseInsensitiveContains(q)
                || ($0.href?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var snapshotModeView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    Task { await store.captureSnapshot(viewportOnly: viewportOnly) }
                } label: {
                    if store.isLoadingSnapshot {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Indexing…")
                        }
                    } else {
                        Label("Capture Snapshot", systemImage: "viewfinder")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isLoadingSnapshot)

                Toggle("Viewport only", isOn: $viewportOnly)
                    .toggleStyle(.checkbox)
                    .font(.callout)

                Menu("Page Scroll") {
                    Button("Scroll Down") { Task { await store.performElementAction(action: "scroll", target: nil, value: "down") } }
                    Button("Scroll Up") { Task { await store.performElementAction(action: "scroll", target: nil, value: "up") } }
                    Divider()
                    Button("Scroll to Top") { Task { await store.performElementAction(action: "scroll", target: nil, value: "top") } }
                    Button("Scroll to Bottom") { Task { await store.performElementAction(action: "scroll", target: nil, value: "bottom") } }
                }
                .fixedSize()

                Spacer()

                TextField("Filter @eN, label, or role…", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)

                if let snap = store.latestSnapshot {
                    CopyButton(text: snap.snapshotText, title: "Copy LLM Tree")
                }
            }
            .padding(12)

            Divider()

            if let snap = store.latestSnapshot {
                HStack(spacing: 12) {
                    Text(snap.title.isEmpty ? snap.url : snap.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text("\(filteredElements.count) of \(snap.elementCount) refs · scroll \(snap.scrollY)/\(snap.maxScrollY) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.03))

                Divider()

                if filteredElements.isEmpty {
                    ContentUnavailableView("No matching elements", systemImage: "magnifyingglass",
                                           description: Text("Try clearing the filter or unchecking Viewport only."))
                } else {
                    List(filteredElements) { el in
                        snapshotRow(el)
                    }
                    .listStyle(.inset)
                }
            } else {
                ContentUnavailableView {
                    Label("Interactive DOM Snapshot", systemImage: "viewfinder")
                } description: {
                    Text("Indexes every visible button, input, and link as compact @e1..@eN references—the exact representation AI agents use over Station MCP (~95% fewer tokens than raw HTML).")
                } actions: {
                    Button("Capture @eN Snapshot") {
                        Task { await store.captureSnapshot(viewportOnly: viewportOnly) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func snapshotRow(_ el: SnapshotElementDTO) -> some View {
        let isInput = el.tag == "input" || el.tag == "textarea" || el.role == "textbox" || el.role == "searchbox" || el.role == "combobox"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                RefBadge(ref: el.ref)

                Text(el.role)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(.secondary)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 1) {
                    Text(el.label.isEmpty ? "<\(el.tag)>" : el.label)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let val = el.value, !val.isEmpty {
                        Text("value: \"\(val)\"")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let href = el.href, !href.isEmpty {
                        Text(href)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                if isInput {
                    Button("Fill…") {
                        if fillTargetRef == el.ref {
                            fillTargetRef = nil
                        } else {
                            fillTargetRef = el.ref
                            fillValue = el.value ?? ""
                        }
                    }
                    .controlSize(.small)
                }

                Button("Click") {
                    Task { await store.performElementAction(action: "click", target: "@\(el.ref)") }
                }
                .controlSize(.small)
                .disabled(el.disabled == true)
            }

            if fillTargetRef == el.ref {
                HStack(spacing: 8) {
                    TextField("Type text into @\(el.ref)…", text: $fillValue)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            submitFill(ref: el.ref, pressEnter: true)
                        }
                    Button("Fill") {
                        submitFill(ref: el.ref, pressEnter: false)
                    }
                    .controlSize(.small)
                    Button("Fill + Enter") {
                        submitFill(ref: el.ref, pressEnter: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.leading, 44)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    private func submitFill(ref: String, pressEnter: Bool) {
        let val = fillValue
        fillTargetRef = nil
        Task {
            await store.performElementAction(action: "fill", target: "@\(ref)", value: val, refreshSnapshotAfter: !pressEnter)
            if pressEnter {
                await store.performElementAction(action: "press", target: "@\(ref)", value: "Enter", refreshSnapshotAfter: true)
            }
        }
    }

    // MARK: - 2. Clean Markdown Reader Mode

    private var readerModeView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    Task { await store.extractCleanMarkdown(customURL: nil) }
                } label: {
                    if store.isLoadingRead {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Extracting…")
                        }
                    } else {
                        Label("Read Selected Tab", systemImage: "doc.plaintext")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isLoadingRead)

                Divider().frame(height: 18)

                TextField("Or read any URL in an ephemeral background tab…", text: $customReadURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        guard !customReadURL.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        let u = customReadURL.contains("://") ? customReadURL : "https://\(customReadURL)"
                        Task { await store.extractCleanMarkdown(customURL: u) }
                    }
                Button("Fetch URL") {
                    let u = customReadURL.contains("://") ? customReadURL : "https://\(customReadURL)"
                    Task { await store.extractCleanMarkdown(customURL: u) }
                }
                .disabled(customReadURL.trimmingCharacters(in: .whitespaces).isEmpty || store.isLoadingRead)

                if let doc = store.latestRead {
                    CopyButton(text: doc.markdown, title: "Copy Markdown")
                }
            }
            .padding(12)

            Divider()

            if let doc = store.latestRead {
                HStack(spacing: 12) {
                    Text(doc.title.isEmpty ? doc.url : doc.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(String(format: "-%.1f%% vs HTML", doc.tokenSavingsPct))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .foregroundStyle(.green)
                        .background(Color.green.opacity(0.13), in: Capsule())
                    Text("~\(doc.estimatedTokens) tokens (\(doc.markdownChars) chars)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.03))

                Divider()

                ScrollView {
                    Text(doc.markdown)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
            } else {
                ContentUnavailableView {
                    Label("Authenticated Clean Reader", systemImage: "doc.plaintext")
                } description: {
                    Text("Strips ads, scripts, and navigation clutter into clean Markdown—using your real logged-in Chrome cookies (works on LinkedIn, Facebook Groups, Reddit, X, and Notion with zero API fees).")
                } actions: {
                    Button("Read Selected Tab") {
                        Task { await store.extractCleanMarkdown(customURL: nil) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    // MARK: - 3. JS Console Mode

    private let jsPresets: [(String, String)] = [
        ("Page Summary", "({ title: document.title, url: location.href, links: document.links.length, forms: document.forms.length })"),
        ("All Links", "[...document.querySelectorAll('a[href]')].slice(0, 30).map(a => ({ text: a.innerText.trim().slice(0, 80), href: a.href })).filter(x => x.text)"),
        ("Next.js / JSON-LD", "(() => { const n = document.getElementById('__NEXT_DATA__'); return n ? Object.keys(JSON.parse(n.textContent).props?.pageProps || {}) : [...document.querySelectorAll('script[type=\"application/ld+json\"]')].map(s => JSON.parse(s.textContent)); })()"),
        ("Scroll Bottom", "(window.scrollTo(0, document.body.scrollHeight), { scrollY: window.scrollY, height: document.body.scrollHeight })"),
    ]

    private var evalModeView: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text("Presets:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(jsPresets, id: \.0) { preset in
                        Button(preset.0) {
                            store.evalCode = preset.1
                            Task { await store.runJSEval(preset.1) }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $store.evalCode)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 110)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))

                HStack {
                    if store.evalLatencyMs > 0 {
                        LatencyBadge(ms: store.evalLatencyMs)
                    }
                    Spacer()
                    CopyButton(text: store.evalOutput, title: "Copy Result")
                    Button {
                        Task { await store.runJSEval() }
                    } label: {
                        Label(store.isRunningEval ? "Running…" : "Evaluate (⌘↩)", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.isRunningEval || store.evalCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(14)

            Divider()

            ScrollView {
                Text(store.evalOutput.isEmpty ? "// Return value appears here as formatted JSON." : store.evalOutput)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(store.evalOutput.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    // MARK: - 4. Chat Prompt Injector Mode

    private let chatExamples = [
        "Summarize the key trade-offs in 5 concise bullet points.",
        "Review this architecture for failure modes and latency bottlenecks.",
        "Draft a concise outreach note tailored to this engineering team.",
    ]

    private var canSendPrompt: Bool {
        !store.isExecutingPrompt
            && store.token != nil
            && !store.testPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var chatModeView: some View {
        VStack(spacing: 0) {
            if store.testResponse.isEmpty && !store.isExecutingPrompt {
                ContentUnavailableView {
                    Label("CSP-Safe Chat Prompt Injector", systemImage: "text.bubble")
                } description: {
                    Text("Types a prompt into web chat editors (Gemini, Claude, ChatGPT, ProseMirror) without violating TrustedHTML CSP, triggers Send, and streams the reply back.")
                } actions: {
                    VStack(spacing: 6) {
                        ForEach(chatExamples, id: \.self) { example in
                            Button(example) {
                                store.testPrompt = example
                                composing = true
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        if store.isExecutingPrompt {
                            ProgressView().controlSize(.small)
                            Text("Streaming model response…")
                        } else {
                            Text("\(store.testResponse.count) characters")
                        }
                        Spacer()
                        CopyButton(text: store.testResponse)
                        Button("Clear") { store.clearTestResponse() }
                            .disabled(store.isExecutingPrompt)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    Divider()
                    ScrollView {
                        Text(store.testResponse)
                            .textSelection(.enabled)
                            .lineSpacing(3)
                            .frame(maxWidth: 780, alignment: .leading)
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $store.testPrompt)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .focused($composing)
                        .frame(minHeight: 54, maxHeight: 130)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.testPrompt.isEmpty {
                        Text("Write a prompt to inject into \(store.targetSummaryLabel)…")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                    composing ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12)))

                HStack {
                    Text("⌘↩ to inject & send")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Send Prompt") {
                        Task { await store.executePrompt() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSendPrompt)
                }
            }
            .padding(14)
        }
    }

    // MARK: - Live Visual Preview Sidebar

    private var visualPreviewSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Viewport preview").cardTitle()
                Spacer()
                Button {
                    Task { await store.captureVisualPreview() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .disabled(store.isLoadingScreenshot)
                .help("Capture fresh screenshot of selected tab")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if store.isLoadingScreenshot {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let b64 = store.latestScreenshotBase64,
                      let data = Data(base64Encoded: b64),
                      let nsImg = NSImage(data: data) {
                ScrollView {
                    Image(nsImage: nsImg)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            } else {
                ContentUnavailableView {
                    Label("No preview yet", systemImage: "camera")
                } actions: {
                    Button("Capture Tab") {
                        Task { await store.captureVisualPreview() }
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.02))
    }
}
