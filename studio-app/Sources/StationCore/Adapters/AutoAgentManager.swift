import Foundation
import Combine
import CryptoKit

public struct AutoJobTemplate: Identifiable, Sendable {
    public let id: String
    public let category: FindingCategory
    public let title: String
    public let subtitle: String
    public let iconName: String
    public let goal: String
    public let defaultIntervalMinutes: Int
}

@MainActor
public final class AutoAgentManager: ObservableObject {
    public static let shared = AutoAgentManager()

    // MARK: - Published State

    @Published public private(set) var runStatus: AgentRunStatus = .active
    @Published public private(set) var missions: [AgentMission] = []
    @Published public private(set) var tools: [AgentTool] = []
    @Published public private(set) var actionLogs: [AgentActionLog] = []

    @Published public private(set) var heartbeatCount: Int = 0
    @Published public private(set) var lastHeartbeatAt: Date?
    @Published public var heartbeatIntervalSeconds: Int = 15
    @Published public private(set) var runningMissionId: String?

    // Directories
    public let homeDir: URL
    public let memoryDir: URL
    public let toolsDir: URL
    public let downloadsDir: URL

    public static let templates: [AutoJobTemplate] = [
        AutoJobTemplate(
            id: "rent-watch",
            category: .housing,
            title: "Rent & Housing Watcher",
            subtitle: "Avito, Mubawab & Facebook Groups -> scores districts, WhatsApp links & price drops.",
            iconName: "house",
            goal: "script:~/Desktop/gemini-station-workspace/rent-finder/rent_watch.py",
            defaultIntervalMinutes: 15
        ),
        AutoJobTemplate(
            id: "job-watch",
            category: .jobs,
            title: "Multi-Board Job Hunter",
            subtitle: "Scans LinkedIn & Hacker News Jobs in background tabs, scores stack fit & salaries.",
            iconName: "briefcase",
            goal: "script:~/Desktop/gemini-station-workspace/job-finder/job_watch.py",
            defaultIntervalMinutes: 30
        ),
        AutoJobTemplate(
            id: "leads-radar",
            category: .leads,
            title: "Freelance & B2B Lead Radar",
            subtitle: "Captures fresh engineering & SaaS leads from Reddit r/forhire or custom boards.",
            iconName: "person.2.wave.2",
            goal: "url:https://old.reddit.com/r/forhire/new/",
            defaultIntervalMinutes: 30
        ),
        AutoJobTemplate(
            id: "deals-sniper",
            category: .deals,
            title: "Deals & Marketplace Sniper",
            subtitle: "Tracks second-hand tech, cars, or equipment listings and charts price distribution.",
            iconName: "tag",
            goal: "url:https://www.avito.ma/fr/casablanca/ordinateurs_portables",
            defaultIntervalMinutes: 45
        ),
    ]

    private var heartbeatTask: Task<Void, Never>?
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }()

    public init(baseDirectory: URL? = nil) {
        let base = baseDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".flossi/agent_home")
        self.homeDir = base
        self.memoryDir = base.appendingPathComponent("memory")
        self.toolsDir = base.appendingPathComponent("tools")
        self.downloadsDir = base.appendingPathComponent("downloads")

        reloadStateFromDisk()
        startHeartbeatLoop()
    }

    deinit {
        heartbeatTask?.cancel()
    }

    // MARK: - Disk Persistence

    public func reloadStateFromDisk() {
        try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)

        let cfgPath = homeDir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: cfgPath),
           let cfg = try? jsonDecoder.decode(AutoAgentConfigDTO.self, from: data) {
            self.runStatus = (cfg.status == "active") ? .active : .paused
            self.heartbeatIntervalSeconds = cfg.heartbeatIntervalSeconds
        }

        let missionsPath = memoryDir.appendingPathComponent("missions.json")
        if let data = try? Data(contentsOf: missionsPath),
           let loadedMissions = try? jsonDecoder.decode([AgentMission].self, from: data) {
            self.missions = loadedMissions
        }

        let registryPath = toolsDir.appendingPathComponent("registry.json")
        if let data = try? Data(contentsOf: registryPath),
           let loadedTools = try? jsonDecoder.decode([AgentTool].self, from: data) {
            self.tools = loadedTools
        }

        if actionLogs.isEmpty {
            appendLog(type: "BOOTSTRAP", detail: "Loaded \(tools.count) tools and \(missions.count) missions from \(homeDir.path).", isSuccess: true)
        }
    }

    private func saveMissionsToDisk() {
        let path = memoryDir.appendingPathComponent("missions.json")
        if let data = try? jsonEncoder.encode(missions) {
            try? data.write(to: path, options: .atomic)
        }
    }

    private func saveConfigToDisk() {
        let path = homeDir.appendingPathComponent("config.json")
        let dto = AutoAgentConfigDTO(
            agentId: "homunculus-01",
            name: "Station Auto-Jobs Scheduler",
            status: runStatus == .active ? "active" : "paused",
            heartbeatIntervalSeconds: heartbeatIntervalSeconds,
            maxDailyBudgetDollars: 0.0
        )
        if let data = try? jsonEncoder.encode(dto) {
            try? data.write(to: path, options: .atomic)
        }
    }

    // MARK: - Autonomous Heartbeat & Scheduled Execution

    public func toggleRunStatus() {
        if runStatus == .active {
            runStatus = .paused
            appendLog(type: "STATE_CHANGE", detail: "Auto-Job scheduler paused.", isSuccess: true)
        } else {
            runStatus = .active
            appendLog(type: "STATE_CHANGE", detail: "Auto-Job scheduler resumed.", isSuccess: true)
        }
        saveConfigToDisk()
    }

    public func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                let interval = await MainActor.run { self.heartbeatIntervalSeconds }
                try? await Task.sleep(nanoseconds: UInt64(max(5, interval)) * 1_000_000_000)

                if Task.isCancelled { break }
                await self.performHeartbeatPulse()
            }
        }
    }

    public func performHeartbeatPulse() async {
        guard runStatus == .active else { return }
        heartbeatCount += 1
        let now = Date()
        lastHeartbeatAt = now

        let iso = ISO8601DateFormatter()
        for mission in missions where mission.status == "running" && isActionableGoal(mission.goal) {
            let isDue: Bool
            if let lastStr = mission.lastRunAt, let lastDate = iso.date(from: lastStr) {
                isDue = now.timeIntervalSince(lastDate) >= Double(max(1, mission.intervalMinutes) * 60)
            } else if let createdDate = iso.date(from: mission.createdAt) {
                isDue = now.timeIntervalSince(createdDate) >= Double(max(1, mission.intervalMinutes) * 60)
            } else {
                isDue = false
            }
            if isDue {
                await executeMission(id: mission.id)
            }
        }
    }

    private func isActionableGoal(_ goal: String) -> Bool {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("script:") || trimmed.hasPrefix("tool:") || trimmed.hasPrefix("url:")
    }

    public func inferCategory(for mission: AgentMission) -> FindingCategory {
        let blob = "\(mission.title) \(mission.goal)".lowercased()
        if blob.contains("rent") || blob.contains("housing") || blob.contains("mubawab") || blob.contains("coloc") || blob.contains("appart") {
            return .housing
        }
        if blob.contains("forhire") || blob.contains("lead") || blob.contains("upwork") || blob.contains("freelance") {
            return .leads
        }
        if blob.contains("deal") || blob.contains("sniper") || blob.contains("vinted") || blob.contains("ordinateur") || blob.contains("marketplace") {
            return .deals
        }
        if blob.contains("job") || blob.contains("linkedin") || blob.contains("ycombinator") || blob.contains("career") || blob.contains("hiring") {
            return .jobs
        }
        return .monitors
    }

    public func executeMission(id: String) async {
        guard let idx = missions.firstIndex(where: { $0.id == id }) else { return }
        guard runningMissionId == nil else { return }

        let mission = missions[idx]
        runningMissionId = id
        defer { runningMissionId = nil }

        let goal = mission.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let nowISO = ISO8601DateFormatter().string(from: Date())
        var summary = "Completed check"
        var ok = true

        if goal.lowercased().hasPrefix("tool:") {
            let filename = String(goal.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            await runToolScript(filename: filename)
            summary = "Ran tool \(filename)"
        } else if goal.lowercased().hasPrefix("script:") {
            let rawPath = String(goal.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            let expanded = (rawPath as NSString).expandingTildeInPath
            let (success, out) = await runExternalPythonScript(path: expanded)
            ok = success
            summary = out
        } else if goal.lowercased().hasPrefix("url:") {
            let targetURL = String(goal.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            let cat = inferCategory(for: mission)
            let (success, out) = await extractStructuredFindingsFromURL(url: targetURL, category: cat, jobId: mission.id)
            ok = success
            summary = out
        } else {
            summary = "Checked goal (\(goal.prefix(60)))"
        }

        if let freshIdx = missions.firstIndex(where: { $0.id == id }) {
            missions[freshIdx].lastRunAt = nowISO
            missions[freshIdx].lastResult = summary
            saveMissionsToDisk()
        }

        // Refresh unified Findings & Charts store so new rows appear immediately in UI!
        FindingsStore.shared.reload()
        appendLog(type: "MISSION_RUN", detail: "[\(mission.title)] \(summary)", isSuccess: ok)
    }

    private func runExternalPythonScript(path: String) async -> (Bool, String) {
        guard FileManager.default.fileExists(atPath: path) else {
            return (false, "Script not found at \(path)")
        }
        return await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [path]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let line = out.components(separatedBy: "\n").last ?? "Finished"
                return (proc.terminationStatus == 0, String(line.prefix(140)))
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }

    /// Universal background URL harvester: opens `url` in a hidden Chrome tab on Station,
    /// extracts structured cards/listings/postings, and saves them to `FindingsStore` (`findings.db`).
    private func extractStructuredFindingsFromURL(url: String, category: FindingCategory, jobId: String) async -> (Bool, String) {
        let tokenAdapter = FileTokenAdapter()
        guard let tok = try? tokenAdapter.loadToken() else {
            return (false, "Missing station.token")
        }
        let client = StationClient()
        let createdRes = await client.createTab(url: url, background: true, token: tok.rawValue)
        guard case .success(let tab) = createdRes else {
            return (false, "Station offline or failed to open background tab")
        }

        defer {
            Task { _ = await client.closeTab(targetId: tab.id, token: tok.rawValue) }
        }

        // Wait briefly for SPA hydration
        try? await Task.sleep(nanoseconds: 2_200_000_000)

        let harvestJS = """
        (() => {
            const clean = (s, n = 200) => (s || '').replace(/\\s+/g, ' ').trim().slice(0, n);
            const host = location.hostname.replace(/^www\\./, '');
            const out = [];
            const seen = new Set();

            // Avito Next.js structured payload
            const nextEl = document.getElementById('__NEXT_DATA__');
            if (nextEl) {
                try {
                    const ads = JSON.parse(nextEl.textContent)?.props?.pageProps?.componentProps?.ads?.ads;
                    if (Array.isArray(ads) && ads.length) {
                        for (const a of ads.slice(0, 40)) {
                            out.push({
                                title: clean(a.subject || a.title, 140),
                                subtitle: clean(a.location || host, 90),
                                amount: a.price?.value || null,
                                currency: 'DH',
                                href: a.href || location.href,
                                snippet: clean(a.description || '', 320)
                            });
                        }
                        return out;
                    }
                } catch (_) {}
            }

            // Generic semantic cards / rows (HN, Reddit, LinkedIn, Job Boards, Marketplaces)
            for (const a of document.querySelectorAll('a[href]')) {
                const href = a.href || '';
                if (!href.startsWith('http') || seen.has(href)) continue;
                if (href === location.href || href.includes('/login') || href.includes('/signup')) continue;
                const container = a.closest('article, li, tr.athing, .thing, [class*="card" i], [class*="job" i], [class*="listing" i]');
                if (!container) continue;
                const title = clean(a.innerText || container.querySelector('h1,h2,h3,h4')?.innerText, 150);
                if (title.length < 10) continue;
                seen.add(href);
                const text = clean(container.innerText, 360);
                let amount = null, currency = '$';
                const dh = text.match(/(\\d[\\d\\s.,]{1,7})\\s*(?:dh|mad)/i);
                const usd = text.match(/\\$\\s*(\\d{2,6})(k)?/i);
                if (dh) {
                    amount = parseInt(dh[1].replace(/\\D/g, ''), 10) || null;
                    currency = 'DH';
                } else if (usd) {
                    const n = parseInt(usd[1], 10);
                    amount = usd[2] ? n * 1000 : n;
                    currency = '$';
                }
                out.push({ title, subtitle: host, amount, currency, href: href.split('#')[0], snippet: text });
                if (out.length >= 35) break;
            }
            return out;
        })()
        """

        let cmd = CommandRequestDTO(action: "exec", code: harvestJS, session: nil, targetId: tab.id)
        let evalRes = await client.executeCommand(request: cmd, token: tok.rawValue)
        guard case .success(let resp) = evalRes, resp.ok, case .array(let items) = resp.data else {
            return (false, "Could not extract items from \(url)")
        }

        let sourceHost = (URL(string: url)?.host ?? "web")
            .replacingOccurrences(of: "www.", with: "")
            .replacingOccurrences(of: "old.", with: "")
            .components(separatedBy: ".")
            .first ?? "web"

        var newCount = 0
        for val in items {
            guard case .dictionary(let d) = val,
                  let title = d["title"]?.stringValue, !title.isEmpty,
                  let href = d["href"]?.stringValue else { continue }
            let subtitle = d["subtitle"]?.stringValue ?? sourceHost
            let snippet = d["snippet"]?.stringValue ?? ""
            let currency = d["currency"]?.stringValue ?? "$"
            var amount: Int?
            if case .int(let a) = d["amount"] { amount = a }

            let hash = Insecure.SHA1.hash(data: Data(href.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
            var tags: [String] = []
            var score = 68
            let lower = "\(title) \(snippet)".lowercased()
            if lower.contains("remote") { tags.append("Remote"); score += 14 }
            if lower.contains("hiring") { tags.append("Hiring"); score += 8 }
            if amount != nil { score += 6 }

            let inserted = FindingsStore.shared.upsertUniversalFinding(
                category: category,
                jobId: jobId,
                source: sourceHost,
                externalId: String(hash),
                title: title,
                subtitle: subtitle,
                amount: amount,
                currency: currency,
                score: min(98, score),
                tags: tags,
                url: href,
                contactURL: href,
                contactLabel: category == .jobs ? "Apply" : (category == .leads ? "Reply" : "Open"),
                snippet: snippet
            )
            if inserted { newCount += 1 }
        }

        return (true, "Saved \(newCount) new (\(items.count) scanned) to Findings")
    }

    // MARK: - Missions Management

    public func addMission(title: String, goal: String, intervalMinutes: Int = 15) {
        let newMission = AgentMission(
            id: "mission-\(UUID().uuidString.prefix(6))",
            title: title,
            goal: goal,
            intervalMinutes: intervalMinutes,
            status: "running"
        )
        missions.insert(newMission, at: 0)
        saveMissionsToDisk()
        appendLog(type: "MISSION_ADDED", detail: "Saved mission '\(title)' (every \(intervalMinutes) min).", isSuccess: true)
    }

    public func toggleMissionPause(id: String) {
        guard let idx = missions.firstIndex(where: { $0.id == id }) else { return }
        missions[idx].status = (missions[idx].status == "running") ? "paused" : "running"
        saveMissionsToDisk()
    }

    public func deleteMission(id: String) {
        missions.removeAll(where: { $0.id == id })
        saveMissionsToDisk()
        appendLog(type: "MISSION_DELETED", detail: "Removed mission [\(id)].", isSuccess: true)
    }

    // MARK: - Tool Execution

    public func runToolScript(filename: String, args: [String] = []) async {
        let scriptPath = toolsDir.appendingPathComponent(filename).path
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            appendLog(type: "TOOL_ERROR", detail: "Tool script '\(filename)' not found.", isSuccess: false)
            return
        }

        let (ok, preview) = await Task.detached { () -> (Bool, String) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [scriptPath] + args

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let firstLine = output.components(separatedBy: "\n").first ?? "Execution finished"
                return (proc.terminationStatus == 0, String(firstLine.prefix(120)))
            } catch {
                return (false, error.localizedDescription)
            }
        }.value

        appendLog(type: ok ? "TOOL_RUN" : "TOOL_ERROR", detail: "[\(filename)] -> \(preview)", isSuccess: ok)

        if let idx = tools.firstIndex(where: { $0.filename == filename }) {
            tools[idx].executionCount += 1
            tools[idx].lastRunAt = ISO8601DateFormatter().string(from: Date())
        }
    }

    // MARK: - Logging

    public func appendLog(type: String, detail: String, isSuccess: Bool = true) {
        let log = AgentActionLog(actionType: type, detail: detail, isSuccess: isSuccess)
        actionLogs.insert(log, at: 0)
        if actionLogs.count > 100 {
            actionLogs.removeLast()
        }
    }
}
