import Foundation
import Combine

@MainActor
public final class StationStore: ObservableObject {
    // MARK: - Published State

    @Published public private(set) var token: StationToken?
    @Published public private(set) var connectionStatus: ConnectionStatus = .offline
    @Published public private(set) var latencyMs: Double = 0.0
    @Published public private(set) var latencyHistory: [Double] = []
    @Published public private(set) var daemonArch: String?
    @Published public private(set) var daemonVersion: String?
    @Published public private(set) var daemonCapabilities: [String] = []
    @Published public private(set) var doctorReport: DoctorResponseDTO?

    @Published public private(set) var activeSession: SessionTarget = .browser
    /// Optional explicit tab target_id (overrides session matching when inspecting multiple tabs on the same host).
    @Published public var pinnedTargetId: String?

    @Published public private(set) var tabTitle: String = "No Tab Connected"
    @Published public private(set) var tabURL: String = ""
    @Published public private(set) var isLoggedIn: Bool = false
    @Published public private(set) var isGenerating: Bool = false
    @Published public private(set) var generatedChars: Int = 0

    @Published public private(set) var rpcLogs: [RPCLogEntry] = []
    @Published public private(set) var tabs: [ChromeTargetDTO] = []

    // Workbench State: Snapshot, Read, Eval, Screenshot & Chat Prompt
    @Published public private(set) var latestSnapshot: SnapshotDataDTO?
    @Published public private(set) var isLoadingSnapshot: Bool = false

    @Published public private(set) var latestRead: ReadDataDTO?
    @Published public private(set) var isLoadingRead: Bool = false

    @Published public private(set) var latestScreenshotBase64: String?
    @Published public private(set) var isLoadingScreenshot: Bool = false

    @Published public var evalCode: String = "({ title: document.title, url: location.href, links: document.links.length })"
    @Published public private(set) var evalOutput: String = ""
    @Published public private(set) var evalLatencyMs: Double = 0.0
    @Published public private(set) var isRunningEval: Bool = false

    @Published public var testPrompt: String = ""
    @Published public private(set) var testResponse: String = ""
    @Published public private(set) var isExecutingPrompt: Bool = false

    /// nil sends commands to the daemon's main tab when no explicit pinnedTargetId is chosen.
    private var commandSession: String? {
        if pinnedTargetId != nil { return nil }
        return activeSession == .browser ? nil : activeSession.rawValue
    }

    public var targetSummaryLabel: String {
        if let tid = pinnedTargetId, let tab = tabs.first(where: { $0.id == tid }) {
            let short = tab.title.isEmpty ? tab.url : tab.title
            return String(short.prefix(34))
        }
        return activeSession.displayName
    }

    // MARK: - Dependencies

    private let tokenAdapter: AuthCredentialsPort
    private let rpcClient: StationRPCPort
    private let promptSynthesizer: PromptSynthesizerPort

    private var pollTask: Task<Void, Never>?
    private var tokenObservationTask: Task<Void, Never>?
    private var observerCount: Int = 0
    private var pollCounter: Int = 0

    public init(
        tokenAdapter: AuthCredentialsPort = FileTokenAdapter(),
        rpcClient: StationRPCPort = StationClient(),
        promptSynthesizer: PromptSynthesizerPort = PromptSynthesizer()
    ) {
        self.tokenAdapter = tokenAdapter
        self.rpcClient = rpcClient
        self.promptSynthesizer = promptSynthesizer

        if let initial = try? tokenAdapter.loadToken() {
            self.token = initial
        }

        self.tokenObservationTask = Task { [weak self] in
            for await newToken in tokenAdapter.observeTokenChanges() {
                guard let self = self else { return }
                await MainActor.run {
                    self.token = newToken
                    self.logRPC(action: "token_rotated", session: "system", payload: newToken.masked, response: "Token updated", latencyMs: 0.1, isSuccess: true)
                }
            }
        }
    }

    deinit {
        pollTask?.cancel()
        tokenObservationTask?.cancel()
    }

    // MARK: - Zero-Idle Visibility Control

    public func setObserved(_ isObserved: Bool) {
        if isObserved {
            observerCount += 1
            if pollTask == nil {
                startPolling()
            }
        } else {
            observerCount = max(0, observerCount - 1)
            if observerCount == 0 {
                stopPolling()
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                await self.refreshNow()
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    break
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Refresh & Health Gauge

    public func refreshNow() async {
        let info = await rpcClient.pingInfo()
        self.daemonArch = info.arch
        self.daemonVersion = info.version
        self.daemonCapabilities = info.capabilities

        if info.ok {
            self.latencyMs = info.latencyMs
            appendLatency(info.latencyMs)

            if let tok = token?.rawValue, !tok.isEmpty {
                let statusRes = await rpcClient.fetchStatus(token: tok)
                switch statusRes {
                case .success(let status):
                    if let data = status.data {
                        self.tabTitle = data.title ?? "Untitled"
                        self.tabURL = data.url ?? ""
                        self.isLoggedIn = data.isLoggedIn ?? false
                        self.isGenerating = data.isGenerating ?? false
                        self.generatedChars = data.chars ?? 0
                        self.connectionStatus = (data.isGenerating ?? false) ? .generating : .online
                    } else {
                        self.connectionStatus = .online
                    }
                case .failure:
                    self.connectionStatus = .degraded
                }
                if case .success(let list) = await rpcClient.fetchTabs(token: tok) {
                    self.tabs = list
                    if let pinned = pinnedTargetId, !list.contains(where: { $0.id == pinned }) {
                        self.pinnedTargetId = nil
                    }
                }
                // Refresh doctor diagnostics periodically (every 5th poll or on first connect)
                if doctorReport == nil || pollCounter % 5 == 0 {
                    if case .success(let doc) = await rpcClient.fetchDoctor(token: tok) {
                        self.doctorReport = doc
                    }
                }
                pollCounter += 1
            } else {
                self.connectionStatus = .unauthorized
            }
        } else {
            self.connectionStatus = .offline
            self.tabs = []
            self.doctorReport = nil
            self.latencyMs = 0.0
            appendLatency(0.0)
        }
    }

    public func refreshDoctorNow() async {
        guard let tok = token?.rawValue, !tok.isEmpty else { return }
        let start = Date()
        switch await rpcClient.fetchDoctor(token: tok) {
        case .success(let doc):
            self.doctorReport = doc
            logRPC(action: "doctor", session: "system", payload: "GET /doctor", response: doc.ok ? "All checks healthy" : "Issues reported", latencyMs: doc.latencyMs ?? (Date().timeIntervalSince(start) * 1000), isSuccess: doc.ok)
        case .failure(let err):
            logRPC(action: "doctor", session: "system", payload: "GET /doctor", response: err.localizedDescription, latencyMs: 0, isSuccess: false)
        }
    }

    private func appendLatency(_ latency: Double) {
        latencyHistory.append(latency)
        if latencyHistory.count > 24 {
            latencyHistory.removeFirst()
        }
    }

    public var minLatencyMs: Double {
        latencyHistory.filter { $0 > 0 }.min() ?? latencyMs
    }

    public var maxLatencyMs: Double {
        latencyHistory.max() ?? latencyMs
    }

    // MARK: - Session & Navigation Actions

    public func switchSession(_ target: SessionTarget) {
        self.pinnedTargetId = nil
        self.activeSession = target
        logRPC(action: "switch_session", session: target.rawValue, payload: target.displayName, response: "Session selected", latencyMs: 0.2, isSuccess: true)
        Task { await refreshNow() }
    }

    public func pinTab(_ targetId: String?) {
        self.pinnedTargetId = targetId
    }

    public func reloadActiveTab() async {
        guard let tok = token?.rawValue else { return }
        let code = "window.location.reload(); 'reloaded'"
        let cmd = CommandRequestDTO(action: "exec", code: code, session: commandSession, targetId: pinnedTargetId)
        let res = await rpcClient.executeCommand(request: cmd, token: tok)
        switch res {
        case .success(let resp):
            logRPC(action: "reload", session: targetSummaryLabel, payload: code, response: resp.data?.displayDescription ?? "ok", latencyMs: resp.latencyMs ?? 1.0, isSuccess: resp.ok)
        case .failure(let err):
            logRPC(action: "reload", session: targetSummaryLabel, payload: code, response: err.localizedDescription, latencyMs: 2.0, isSuccess: false)
        }
        await refreshNow()
    }

    public func navigateTarget(url rawURL: String) async {
        guard let tok = token?.rawValue else { return }
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = (trimmed.contains("://") || trimmed.hasPrefix("about:")) ? trimmed : "https://\(trimmed)"

        let res = await rpcClient.navigate(url: normalized, newTab: false, background: false, session: commandSession, targetId: pinnedTargetId, token: tok)
        switch res {
        case .success:
            logRPC(action: "navigate", session: targetSummaryLabel, payload: normalized, response: "Navigating", latencyMs: 1.5, isSuccess: true)
        case .failure(let err):
            logRPC(action: "navigate", session: targetSummaryLabel, payload: normalized, response: err.localizedDescription, latencyMs: 1.5, isSuccess: false)
        }
        try? await Task.sleep(nanoseconds: 450_000_000)
        await refreshNow()
    }

    // MARK: - Workbench: Snapshot, Act, Read, Eval & Screenshot

    public func captureSnapshot(viewportOnly: Bool = false) async {
        guard let tok = token?.rawValue else { return }
        isLoadingSnapshot = true
        defer { isLoadingSnapshot = false }

        switch await rpcClient.fetchSnapshot(viewportOnly: viewportOnly, session: commandSession, targetId: pinnedTargetId, token: tok) {
        case .success(let resp):
            if resp.ok, let data = resp.data {
                self.latestSnapshot = data
                logRPC(action: "snapshot", session: targetSummaryLabel, payload: viewportOnly ? "viewport_only" : "full_page", response: "\(data.elementCount) interactive @eN refs", latencyMs: resp.latencyMs ?? 2.0, isSuccess: true)
            } else {
                logRPC(action: "snapshot", session: targetSummaryLabel, payload: "snapshot", response: resp.error ?? "Failed", latencyMs: resp.latencyMs ?? 2.0, isSuccess: false)
            }
        case .failure(let err):
            logRPC(action: "snapshot", session: targetSummaryLabel, payload: "snapshot", response: err.localizedDescription, latencyMs: 0, isSuccess: false)
        }
    }

    public func performElementAction(action: String, target: String?, value: String? = nil, refreshSnapshotAfter: Bool = true) async {
        guard let tok = token?.rawValue else { return }
        let req = ActRequestDTO(action: action, target: target, value: value, session: commandSession, targetId: pinnedTargetId)
        switch await rpcClient.performAct(request: req, token: tok) {
        case .success(let resp):
            logRPC(
                action: "act.\(action)",
                session: targetSummaryLabel,
                payload: "\(target ?? "page") \(value ?? "")".trimmingCharacters(in: .whitespaces),
                response: resp.error ?? resp.data?.displayDescription ?? "ok",
                latencyMs: resp.latencyMs ?? 1.5,
                isSuccess: resp.ok
            )
        case .failure(let err):
            logRPC(action: "act.\(action)", session: targetSummaryLabel, payload: target ?? "", response: err.localizedDescription, latencyMs: 0, isSuccess: false)
        }

        if refreshSnapshotAfter {
            try? await Task.sleep(nanoseconds: 250_000_000)
            await captureSnapshot()
            if latestScreenshotBase64 != nil {
                await captureVisualPreview()
            }
        }
    }

    public func extractCleanMarkdown(customURL: String? = nil) async {
        guard let tok = token?.rawValue else { return }
        isLoadingRead = true
        defer { isLoadingRead = false }

        switch await rpcClient.fetchRead(url: customURL, session: commandSession, targetId: pinnedTargetId, token: tok) {
        case .success(let resp):
            if resp.ok, let data = resp.data {
                self.latestRead = data
                logRPC(
                    action: "read",
                    session: customURL ?? targetSummaryLabel,
                    payload: customURL ?? "active tab",
                    response: "\(data.markdownChars) chars (-\(String(format: "%.1f", data.tokenSavingsPct))% vs HTML)",
                    latencyMs: resp.latencyMs ?? 3.0,
                    isSuccess: true
                )
            } else {
                logRPC(action: "read", session: targetSummaryLabel, payload: "read", response: resp.error ?? "Failed", latencyMs: resp.latencyMs ?? 0, isSuccess: false)
            }
        case .failure(let err):
            logRPC(action: "read", session: targetSummaryLabel, payload: "read", response: err.localizedDescription, latencyMs: 0, isSuccess: false)
        }
    }

    public func captureVisualPreview(fullPage: Bool = false) async {
        guard let tok = token?.rawValue else { return }
        isLoadingScreenshot = true
        defer { isLoadingScreenshot = false }

        switch await rpcClient.captureScreenshot(session: commandSession, targetId: pinnedTargetId, fullPage: fullPage, token: tok) {
        case .success(let resp):
            if resp.ok, let b64 = resp.imageBase64 {
                self.latestScreenshotBase64 = b64
                let kb = Double(b64.count) * 0.75 / 1024.0
                logRPC(action: "screenshot", session: targetSummaryLabel, payload: fullPage ? "full_page" : "viewport", response: String(format: "%.0f KB JPEG", kb), latencyMs: resp.latencyMs ?? 8.0, isSuccess: true)
            } else {
                logRPC(action: "screenshot", session: targetSummaryLabel, payload: "screenshot", response: resp.error ?? "Failed", latencyMs: 0, isSuccess: false)
            }
        case .failure(let err):
            logRPC(action: "screenshot", session: targetSummaryLabel, payload: "screenshot", response: err.localizedDescription, latencyMs: 0, isSuccess: false)
        }
    }

    public func runJSEval(_ customCode: String? = nil) async {
        guard let tok = token?.rawValue else { return }
        let code = (customCode ?? evalCode).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        isRunningEval = true
        defer { isRunningEval = false }

        let cmd = CommandRequestDTO(action: "exec", code: code, session: commandSession, targetId: pinnedTargetId)
        switch await rpcClient.executeCommand(request: cmd, token: tok) {
        case .success(let resp):
            self.evalLatencyMs = resp.latencyMs ?? 0
            if resp.ok {
                self.evalOutput = resp.data?.prettyJSON ?? "null"
            } else {
                self.evalOutput = "Error: \(resp.error ?? "Evaluation failed")"
            }
            logRPC(action: "eval", session: targetSummaryLabel, payload: String(code.prefix(80)), response: resp.error ?? resp.data?.displayDescription ?? "null", latencyMs: resp.latencyMs ?? 0.5, isSuccess: resp.ok)
        case .failure(let err):
            self.evalOutput = "Network error: \(err.localizedDescription)"
            logRPC(action: "eval", session: targetSummaryLabel, payload: String(code.prefix(80)), response: err.localizedDescription, latencyMs: 0, isSuccess: false)
        }
    }

    // MARK: - Tabs

    public func openTab(url: String, background: Bool = false) async {
        guard let tok = token?.rawValue else { return }
        switch await rpcClient.createTab(url: url, background: background, token: tok) {
        case .success(let tab):
            logRPC(action: background ? "open_bg_tab" : "open_tab", session: "tabs", payload: url, response: tab.id, latencyMs: 0, isSuccess: true)
        case .failure(let err):
            logRPC(action: "open_tab", session: "tabs", payload: url, response: err.localizedDescription, latencyMs: 0, isSuccess: false)
        }
        await refreshNow()
    }

    public func activateTab(_ id: String) async {
        guard let tok = token?.rawValue else { return }
        _ = await rpcClient.activateTab(targetId: id, token: tok)
    }

    public func closeTab(_ id: String) async {
        guard let tok = token?.rawValue else { return }
        if pinnedTargetId == id { pinnedTargetId = nil }
        let res = await rpcClient.closeTab(targetId: id, token: tok)
        if case .failure(let err) = res {
            logRPC(action: "close_tab", session: "tabs", payload: id, response: err.localizedDescription, latencyMs: 0, isSuccess: false)
        } else {
            logRPC(action: "close_tab", session: "tabs", payload: id, response: "closed", latencyMs: 0, isSuccess: true)
        }
        await refreshNow()
    }

    public func generateNewToken() {
        do {
            let newToken = try tokenAdapter.generateNewToken()
            self.token = newToken
            logRPC(action: "generate_token", session: "auth", payload: "32 bytes mode 0600", response: "Success: \(newToken.masked)", latencyMs: 1.0, isSuccess: true)
        } catch {
            logRPC(action: "generate_token", session: "auth", payload: "32 bytes", response: error.localizedDescription, latencyMs: 1.0, isSuccess: false)
        }
    }

    public func clearLogs() {
        rpcLogs.removeAll()
    }

    // MARK: - Prompt Execution & Streaming Playground

    public func executePrompt(_ customText: String? = nil) async {
        let promptToRun = customText ?? testPrompt
        guard !promptToRun.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let tok = token?.rawValue else { return }

        isExecutingPrompt = true
        testResponse = "Injecting prompt into \(targetSummaryLabel)…"

        let injectionCode = promptSynthesizer.synthesizeInjectionJS(prompt: promptToRun)
        let injectCmd = CommandRequestDTO(action: "exec", code: injectionCode, session: commandSession, targetId: pinnedTargetId)

        let injectRes = await rpcClient.executeCommand(request: injectCmd, token: tok)
        switch injectRes {
        case .success(let injectResp):
            var failure = injectResp.ok ? nil : (injectResp.error ?? "Station rejected the command")
            if case .dictionary(let dict) = injectResp.data, let message = dict["error"]?.stringValue {
                failure = message
            }
            logRPC(action: "inject_prompt", session: targetSummaryLabel, payload: promptToRun.prefix(60) + "...", response: failure ?? injectResp.data?.displayDescription ?? "Injected", latencyMs: injectResp.latencyMs ?? 5.0, isSuccess: failure == nil)

            if let failure {
                testResponse = "Couldn't send the prompt: \(failure)"
                isExecutingPrompt = false
                return
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
            let sendCode = promptSynthesizer.synthesizeSendClickJS()
            let sendCmd = CommandRequestDTO(action: "exec", code: sendCode, session: commandSession, targetId: pinnedTargetId)
            _ = await rpcClient.executeCommand(request: sendCmd, token: tok)

            await monitorGenerationCompletion(token: tok)

        case .failure(let err):
            testResponse = "Error: \(err.localizedDescription)"
            isExecutingPrompt = false
            logRPC(action: "inject_prompt", session: targetSummaryLabel, payload: promptToRun, response: err.localizedDescription, latencyMs: 5.0, isSuccess: false)
        }
    }

    public func clearTestResponse() {
        self.testResponse = ""
    }

    private func monitorGenerationCompletion(token: String) async {
        testResponse = "Waiting for model reply…"
        let startTime = Date()
        var stableCount = 0
        var lastChars = -1

        let checkCode = promptSynthesizer.synthesizeGenerationCheckJS()
        let extractCode = promptSynthesizer.synthesizeResponseExtractJS()

        while Date().timeIntervalSince(startTime) < 90.0 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            let checkCmd = CommandRequestDTO(action: "exec", code: checkCode, session: commandSession, targetId: pinnedTargetId)
            let checkRes = await rpcClient.executeCommand(request: checkCmd, token: token)

            if case .success(let checkResp) = checkRes,
               case .dictionary(let dict) = checkResp.data {
                let isGen = dict["isGenerating"] == .bool(true)
                var currentChars = 0
                if case .int(let c) = dict["chars"] { currentChars = c }

                if currentChars > 20 {
                    let extractCmd = CommandRequestDTO(action: "exec", code: extractCode, session: commandSession, targetId: pinnedTargetId)
                    if case .success(let extResp) = await rpcClient.executeCommand(request: extractCmd, token: token),
                       let text = extResp.data?.stringValue {
                        self.testResponse = text
                    }
                }

                if currentChars > 50 && currentChars == lastChars {
                    stableCount += 1
                } else {
                    stableCount = 0
                }
                lastChars = currentChars

                if !isGen && stableCount >= 2 {
                    break
                }
            }
        }

        let finalCmd = CommandRequestDTO(action: "exec", code: extractCode, session: commandSession, targetId: pinnedTargetId)
        if case .success(let finalResp) = await rpcClient.executeCommand(request: finalCmd, token: token),
           let text = finalResp.data?.stringValue {
            self.testResponse = text
            logRPC(action: "completion", session: targetSummaryLabel, payload: "\(text.count) chars received", response: "OK", latencyMs: Double(Date().timeIntervalSince(startTime) * 1000).rounded() / 100, isSuccess: true)
        }
        isExecutingPrompt = false
    }

    private func logRPC(action: String, session: String, payload: String, response: String, latencyMs: Double, isSuccess: Bool) {
        let entry = RPCLogEntry(
            action: action,
            session: session,
            payloadSummary: payload,
            responseSummary: response,
            latencyMs: latencyMs,
            isSuccess: isSuccess
        )
        rpcLogs.insert(entry, at: 0)
        if rpcLogs.count > 120 {
            rpcLogs.removeLast()
        }
    }
}
