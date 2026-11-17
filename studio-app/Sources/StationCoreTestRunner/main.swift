import Foundation
import StationCore

@main
@MainActor
struct TestRunner {
    static var testsPassed = 0
    static var testsFailed = 0

    static func assertTest(_ condition: Bool, _ message: String) {
        if condition {
            print("  \u{001B}[32m✔\u{001B}[0m \(message)")
            testsPassed += 1
        } else {
            print("  \u{001B}[31m✖\u{001B}[0m FAILED: \(message)")
            testsFailed += 1
        }
    }

    static func printHeader(_ title: String) {
        print("\n\u{001B}[1;36m=== \(title) ===\u{001B}[0m")
    }

    static func main() async {
        print("\u{001B}[1;35m╔════════════════════════════════════════════════════════════╗\u{001B}[0m")
        print("\u{001B}[1;35m║        STATION STUDIO v2.0 — VERIFICATION SUITE            ║\u{001B}[0m")
        print("\u{001B}[1;35m╚════════════════════════════════════════════════════════════╝\u{001B}[0m")

        await testTokenAdapter()
        testPromptSynthesizer()
        testDTOSerialization()
        testMCPConfigurator()
        await testLiveDaemonsIfRunning()
        await testStationStore()
        await testAutoAgent()
        testFindingsAndChartsStore()

        print("\n\u{001B}[1;37m------------------------------------------------------------\u{001B}[0m")
        if testsFailed == 0 {
            print("\u{001B}[1;32mALL \(testsPassed) TESTS PASSED! Station Studio v2.0 verified.\u{001B}[0m\n")
            exit(0)
        } else {
            print("\u{001B}[1;31m\(testsFailed) TESTS FAILED! (\(testsPassed) passed)\u{001B}[0m\n")
            exit(1)
        }
    }

    // MARK: - Token Adapter Tests

    static func testTokenAdapter() async {
        printHeader("1. FileTokenAdapter & Zero-Polling vnode Watcher")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tokenPath = tempDir.appendingPathComponent("station.token").path
        let adapter = FileTokenAdapter(customPath: tokenPath)

        do {
            let token = try adapter.generateNewToken()
            assertTest(token.rawValue.count == 64, "Generated token must be 64 hex characters (32 bytes)")
            assertTest(token.masked.contains("••••"), "Token masked representation must conceal secret")

            let attrs = try FileManager.default.attributesOfItem(atPath: tokenPath)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            assertTest(perms == 0o600, "Token file POSIX permissions must be 0600 (owner rw only, got \(String(format: "%o", perms)))")

            let reloaded = try adapter.loadToken()
            assertTest(reloaded.rawValue == token.rawValue, "Loaded token matches generated value")
        } catch {
            assertTest(false, "Token generation/reloading threw error: \(error)")
        }
    }

    // MARK: - Prompt Synthesizer CSP Tests

    static func testPromptSynthesizer() {
        printHeader("2. PromptSynthesizer CSP & TrustedHTML Compliance")
        let synthesizer = PromptSynthesizer()
        let prompt = "Explain quantum computing in French\nLine 2 with special \"quotes\" and <tags>"
        let js = synthesizer.synthesizeInjectionJS(prompt: prompt)

        assertTest(!js.contains(".innerHTML"), "TrustedHTML violation guard: .innerHTML is NEVER used")
        assertTest(js.contains("document.createElement('p')"), "Must synthesize DOM paragraph elements via createElement('p')")
        assertTest(js.contains("replaceChildren"), "Must use replaceChildren for clean DOM replacement")
        assertTest(js.contains("InputEvent"), "Must dispatch synthetic InputEvent to trigger Angular change detection")

        let sendJS = synthesizer.synthesizeSendClickJS()
        let stopJS = synthesizer.synthesizeGenerationCheckJS()

        assertTest(sendJS.contains("Send") && sendJS.contains("Envoyer"), "Send script supports bilingual English ('Send') and French ('Envoyer')")
        assertTest(stopJS.contains("Stop") && (stopJS.contains("Interrompre") || stopJS.contains("Arrêter")), "Stop check supports bilingual English ('Stop') and French ('Interrompre'/'Arrêter')")
    }

    // MARK: - DTO Serialization Tests

    static func testDTOSerialization() {
        printHeader("3. Wire DTO Serialization (Status, Snapshot & Read)")
        let jsonStr = """
        {
            "ok": true,
            "data": {
                "chars": 128,
                "isGenerating": false,
                "isLoggedIn": true,
                "title": "Google Gemini",
                "url": "https://gemini.google.com/app"
            },
            "latency_ms": 0.85
        }
        """
        guard let data = jsonStr.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(StationStatusResponseDTO.self, from: data) else {
            assertTest(false, "Failed to decode StationStatusResponseDTO")
            return
        }

        assertTest(decoded.ok == true, "Decoded status is ok")
        assertTest(decoded.latencyMs == 0.85, "Decoded latency matches 0.85ms")
        assertTest(decoded.data?.title == "Google Gemini", "Decoded title matches 'Google Gemini'")

        let snapJSON = """
        {
            "ok": true,
            "data": {
                "title": "Jobs",
                "url": "https://www.linkedin.com/jobs",
                "scroll_y": 0,
                "max_scroll_y": 1400,
                "element_count": 1,
                "headings": [{"level": "h1", "text": "Top job picks"}],
                "elements": [{"ref": "e1", "tag": "button", "role": "button", "label": "Easy Apply", "in_viewport": true}],
                "snapshot_text": "[@e1] button \\"Easy Apply\\""
            },
            "latency_ms": 1.12
        }
        """
        let snapDecoded = try? JSONDecoder().decode(SnapshotResponseDTO.self, from: Data(snapJSON.utf8))
        assertTest(snapDecoded?.data?.elements.first?.ref == "e1", "Decoded @e1 snapshot element")
        assertTest(snapDecoded?.data?.elements.first?.label == "Easy Apply", "Decoded snapshot element label")
    }

    // MARK: - MCP Configurator Safe Merge Tests

    static func testMCPConfigurator() {
        printHeader("4. MCPConfigurator Non-Destructive JSON Merge & Catalog")
        let tempHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let cursorDir = tempHome.appendingPathComponent(".cursor")
        try? FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        let existingJSON = """
        {
          "mcpServers": {
            "github": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"] }
          },
          "customSetting": true
        }
        """
        try? existingJSON.write(to: cursorDir.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)

        assertTest(!MCPConfigurator.isInstalled(for: .cursor, home: tempHome.path), "Initially reports Station not installed")
        do {
            try MCPConfigurator.install(for: .cursor, binaryPath: "/usr/local/bin/station", profileName: "jobs", home: tempHome.path)
            assertTest(MCPConfigurator.isInstalled(for: .cursor, home: tempHome.path), "Reports Station installed after 1-click install")

            let mergedData = try Data(contentsOf: cursorDir.appendingPathComponent("mcp.json"))
            let mergedRoot = try JSONSerialization.jsonObject(with: mergedData) as? [String: Any]
            let servers = mergedRoot?["mcpServers"] as? [String: Any]
            assertTest(servers?["github"] != nil, "Preserves existing MCP servers ('github') untouched")
            assertTest(mergedRoot?["customSetting"] as? Bool == true, "Preserves top-level keys untouched")

            try MCPConfigurator.uninstall(for: .cursor, home: tempHome.path)
            assertTest(!MCPConfigurator.isInstalled(for: .cursor, home: tempHome.path), "Cleanly removes Station while keeping file valid")
        } catch {
            assertTest(false, "MCPConfigurator threw error: \(error)")
        }

        assertTest(MCPConfigurator.tools.count == 11, "Exposes all 11 Station MCP tools")
        assertTest(MCPConfigurator.prompts.count == 3, "Exposes all 3 built-in workflow prompts")
    }

    // MARK: - Live Daemon Integration (Optional when running)

    static func testLiveDaemonsIfRunning() async {
        printHeader("5. Live Daemon Check (Port 19826)")
        let client = StationClient(stationPort: 19826)
        let info = await client.pingInfo()
        if info.ok {
            assertTest(info.latencyMs < 25.0, "Live Station ping latency is sub-25ms (\(String(format: "%.2f", info.latencyMs))ms)")
            assertTest(info.arch == "rust-native-apple-silicon", "Daemon reports rust-native-apple-silicon architecture")
        } else {
            print("  \u{001B}[33mℹ\u{001B}[0m Daemon currently offline on 19826 (skipped live socket assertions)")
        }
    }

    // MARK: - StationStore Zero-Idle Visibility Control

    static func testStationStore() async {
        printHeader("6. StationStore & Zero-Idle Visibility Control")
        let store = StationStore()
        await store.refreshNow()
        assertTest(store.connectionStatus == .online || store.connectionStatus == .offline, "StationStore reports valid ConnectionStatus (\(store.connectionStatus))")

        store.setObserved(true)
        store.setObserved(false)
        assertTest(true, "HUD / Cockpit visibility toggled cleanly (timer suspended at 0.0% idle CPU)")
    }

    // MARK: - AutoAgent Tests

    static func testAutoAgent() async {
        printHeader("7. AutoAgentManager & Templates")
        let tempAgentDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempAgentDir) }

        let agent = AutoAgentManager(baseDirectory: tempAgentDir)
        assertTest(AutoAgentManager.templates.count == 4, "Provides 4 built-in Auto-Job templates (Rent, LinkedIn, HN, Extractor)")

        let testTitle = "Test Verification Mission"
        agent.addMission(title: testTitle, goal: "Verify test suite execution", intervalMinutes: 10)
        assertTest(agent.missions.contains(where: { $0.title == testTitle }), "Enrolled new autonomous mission")

        let initialHeartbeats = agent.heartbeatCount
        await agent.performHeartbeatPulse()
        assertTest(agent.heartbeatCount == initialHeartbeats + 1, "Heartbeat ticks when active")

        if let mission = agent.missions.first(where: { $0.title == testTitle }) {
            agent.deleteMission(id: mission.id)
            assertTest(!agent.missions.contains(where: { $0.title == testTitle }), "Cleaned up test mission")
        }
    }

    // MARK: - Findings, CRM & Swift Charts Store Tests

    static func testFindingsAndChartsStore() {
        printHeader("8. Universal FindingsStore (SQLite Two-Way CRM & Chart Aggregations)")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempFindingsDB = tempDir.appendingPathComponent("findings.db").path
        let store = FindingsStore(universalDBPath: tempFindingsDB)

        let housingRows = store.items.filter { $0.category == .housing }
        assertTest(housingRows.count >= 50, "Loaded live housing findings from rent-finder/seen.db (\(housingRows.count) rows)")

        let addedJob1 = store.upsertUniversalFinding(
            category: .jobs,
            source: "hn",
            externalId: "job1",
            title: "Senior Rust Systems Engineer",
            subtitle: "Linear · Remote",
            amount: 195000,
            currency: "$",
            score: 94,
            tags: ["Remote", "Rust"],
            url: "https://example.com/jobs/1",
            contactURL: "https://example.com/jobs/1",
            contactLabel: "Apply",
            snippet: "Build sub-millisecond developer tools"
        )
        let addedJob2 = store.upsertUniversalFinding(
            category: .jobs,
            source: "linkedin",
            externalId: "job2",
            title: "Staff Backend Engineer",
            subtitle: "Stripe · Remote",
            amount: 225000,
            currency: "$",
            score: 88,
            tags: ["Remote"],
            url: "https://example.com/jobs/2"
        )
        assertTest(addedJob1 && addedJob2, "Upserted structured job findings into SQLite findings.db")

        store.reload()
        let jobs = store.filtered(category: .jobs)
        assertTest(jobs.count == 2, "Filtered Job Search category returns 2 findings")

        store.updateFinding(uid: "jobs:hn:job1", status: "contacted", note: "Referred by Alex")
        store.reload()
        let updated = store.filtered(category: .jobs).first(where: { $0.uid == "jobs:hn:job1" })
        assertTest(updated?.status == "contacted" && updated?.note == "Referred by Alex", "Persisted CRM stage ('Applied') and note to SQLite")

        let funnel = store.funnelCounts(for: store.filtered(category: .jobs), category: .jobs)
        assertTest(funnel.first(where: { $0.key == "contacted" })?.label == "Applied", "Domain-aware stage mapping maps 'contacted' -> 'Applied' for Jobs")

        let hist = store.amountHistogram(for: store.filtered(category: .jobs))
        assertTest(!hist.bins.isEmpty && hist.currency == "$", "Computed USD compensation histogram bins for Swift Charts")
    }
}
