import Foundation

// MARK: - MCP Client Target Models

public enum MCPClientID: String, CaseIterable, Identifiable, Sendable {
    case claudeCode    = "claude-code"
    case claudeDesktop = "claude-desktop"
    case cursor        = "cursor"
    case windsurf      = "windsurf"
    case antigravity   = "antigravity"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode:    return "Claude Code"
        case .claudeDesktop: return "Claude Desktop"
        case .cursor:        return "Cursor"
        case .windsurf:      return "Windsurf"
        case .antigravity:   return "Antigravity"
        }
    }

    public var subtitle: String {
        switch self {
        case .claudeCode:    return "CLI & IDE agent (~/.claude.json)"
        case .claudeDesktop: return "macOS Desktop app config"
        case .cursor:        return "Global MCP config (~/.cursor/mcp.json)"
        case .windsurf:      return "Codeium Windsurf MCP config"
        case .antigravity:   return "Antigravity global MCP config"
        }
    }

    public var iconName: String {
        switch self {
        case .claudeCode:    return "terminal"
        case .claudeDesktop: return "bubble.left.and.bubble.right"
        case .cursor:        return "cursorarrow.rays"
        case .windsurf:      return "wind"
        case .antigravity:   return "sparkles.rectangle.stack"
        }
    }

    public func configPath(home: String = NSHomeDirectory()) -> String {
        let ns = home as NSString
        switch self {
        case .claudeCode:
            return ns.appendingPathComponent(".claude.json")
        case .claudeDesktop:
            return ns.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .cursor:
            return ns.appendingPathComponent(".cursor/mcp.json")
        case .windsurf:
            return ns.appendingPathComponent(".codeium/windsurf/mcp_config.json")
        case .antigravity:
            return ns.appendingPathComponent(".gemini/antigravity/mcp_config.json")
        }
    }
}

public struct MCPToolSpec: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let category: String
    public let summary: String
    public let readOnly: Bool
    public let exampleArgsJSON: String
}

public struct MCPPromptSpec: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let title: String
    public let summary: String
}

// MARK: - MCP Configurator & Catalog Service

public struct MCPConfigurator: Sendable {
    public init() {}

    /// Finds the compiled `station` Rust binary across workspace, user bin, and Homebrew paths.
    public static func resolveStationBinary(customOverride: String? = nil) -> String {
        if let override = customOverride, !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        if let envBin = ProcessInfo.processInfo.environment["STATION_BINARY"],
           FileManager.default.isExecutableFile(atPath: envBin) {
            return envBin
        }

        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        // 1. Self-contained embedded binary inside Station Studio.app/Contents/MacOS/station
        let bundledBinary = URL(fileURLWithPath: Bundle.main.bundlePath)
            .appendingPathComponent("Contents/MacOS/station")
            .path
        // 2. Relative to app bundle when running from studio-app/dist inside workspace
        let bundleSibling = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent() // dist
            .deletingLastPathComponent() // studio-app
            .deletingLastPathComponent() // workspace root
            .appendingPathComponent("daemon/target/release/station")
            .path

        let candidates = [
            bundledBinary,
            bundleSibling,
            (home as NSString).appendingPathComponent("Desktop/gemini-station-workspace/daemon/target/release/station"),
            (home as NSString).appendingPathComponent(".local/bin/station"),
            (home as NSString).appendingPathComponent(".cargo/bin/station"),
            "/opt/homebrew/bin/station",
            "/usr/local/bin/station",
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return candidates[1]
    }

    public static func serverJSONSnippet(binaryPath: String, profileName: String? = nil) -> String {
        var args = ["mcp", "--auto-start"]
        if let prof = profileName, !prof.isEmpty, prof != "default" {
            args.append(contentsOf: ["--profile-name", prof])
        }
        let dict: [String: Any] = [
            "mcpServers": [
                "station": [
                    "command": binaryPath,
                    "args": args
                ]
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return ""
    }

    public static func claudeCodeCLICommand(binaryPath: String) -> String {
        let quoted = binaryPath.contains(" ") ? "\"\(binaryPath)\"" : binaryPath
        return "claude mcp add station -- \(quoted) mcp --auto-start"
    }

    /// Checks whether `"station"` is configured under `"mcpServers"` in a client's JSON file.
    public static func isInstalled(for client: MCPClientID, home: String = NSHomeDirectory()) -> Bool {
        let path = client.configPath(home: home)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else {
            return false
        }
        return servers["station"] != nil
    }

    /// Safely merges `"station"` into the target client's `mcpServers` dictionary without clobbering existing entries.
    public static func install(for client: MCPClientID, binaryPath: String, profileName: String? = nil, home: String = NSHomeDirectory()) throws {
        let path = client.configPath(home: home)
        let url = URL(fileURLWithPath: path)
        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path) {
            let existingData = try Data(contentsOf: url)
            if !existingData.isEmpty {
                guard let parsed = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
                    throw NSError(domain: "MCPConfigurator", code: 422, userInfo: [NSLocalizedDescriptionKey: "Existing config at \(path) is not a JSON object."])
                }
                root = parsed
            }
        }

        var args = ["mcp", "--auto-start"]
        if let prof = profileName, !prof.isEmpty, prof != "default" {
            args.append(contentsOf: ["--profile-name", prof])
        }

        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers["station"] = [
            "command": binaryPath,
            "args": args
        ]
        root["mcpServers"] = servers

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: url, options: .atomic)
    }

    /// Removes `"station"` from a client's `mcpServers` dictionary while preserving all other entries.
    public static func uninstall(for client: MCPClientID, home: String = NSHomeDirectory()) throws {
        let path = client.configPath(home: home)
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }

        let existingData = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: existingData) as? [String: Any],
              var servers = root["mcpServers"] as? [String: Any] else {
            return
        }
        servers.removeValue(forKey: "station")
        root["mcpServers"] = servers

        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: url, options: .atomic)
    }

    // MARK: - Built-in Tool & Workflow Catalog

    public static let tools: [MCPToolSpec] = [
        MCPToolSpec(
            name: "station_snapshot",
            category: "Perception",
            summary: "Indexes visible buttons, inputs, and links as @e1..@eN refs (~95% fewer tokens than HTML).",
            readOnly: true,
            exampleArgsJSON: "{ \"viewport_only\": false }"
        ),
        MCPToolSpec(
            name: "station_act",
            category: "Interaction",
            summary: "Clicks, fills React/Vue/Angular inputs, selects options, presses keys, or scrolls using @eN refs.",
            readOnly: false,
            exampleArgsJSON: "{ \"action\": \"click\", \"target\": \"@e1\" }"
        ),
        MCPToolSpec(
            name: "station_read",
            category: "Perception",
            summary: "Extracts clean Markdown + structured metadata from an open tab or any URL in a background tab.",
            readOnly: true,
            exampleArgsJSON: "{ \"max_chars\": 30000 }"
        ),
        MCPToolSpec(
            name: "station_upload",
            category: "Interaction",
            summary: "Attaches local files (PDF resume, images, CSV) via DataTransfer without file-chooser popups.",
            readOnly: false,
            exampleArgsJSON: "{ \"files\": [\"/path/to/resume.pdf\"], \"selector\": \"@e9\" }"
        ),
        MCPToolSpec(
            name: "station_tabs",
            category: "Navigation",
            summary: "Lists tabs, opens background tabs without stealing focus, brings tabs forward, or closes tabs.",
            readOnly: false,
            exampleArgsJSON: "{ \"action\": \"list\" }"
        ),
        MCPToolSpec(
            name: "station_navigate",
            category: "Navigation",
            summary: "Navigates the main tab or a specific session/target_id to an http(s) URL.",
            readOnly: false,
            exampleArgsJSON: "{ \"url\": \"https://www.linkedin.com/jobs\" }"
        ),
        MCPToolSpec(
            name: "station_screenshot",
            category: "Perception",
            summary: "Returns native MCP image blocks (PNG/JPEG) so multimodal models inspect page layout visually.",
            readOnly: true,
            exampleArgsJSON: "{ \"format\": \"jpeg\", \"full_page\": false }"
        ),
        MCPToolSpec(
            name: "station_eval",
            category: "Execution",
            summary: "Runs async/sync JavaScript inside V8 at ~0.36ms persistent WebSocket latency.",
            readOnly: false,
            exampleArgsJSON: "{ \"code\": \"({ title: document.title, links: document.links.length })\" }"
        ),
        MCPToolSpec(
            name: "station_inject",
            category: "Execution",
            summary: "CSP/TrustedHTML-safe prompt injection into Gemini, Claude, or ChatGPT web editors.",
            readOnly: false,
            exampleArgsJSON: "{ \"prompt\": \"Summarize this thread\", \"auto_send\": true }"
        ),
        MCPToolSpec(
            name: "station_status",
            category: "Diagnostics",
            summary: "Checks active tab URL, title, readyState, and loopback latency.",
            readOnly: true,
            exampleArgsJSON: "{}"
        ),
        MCPToolSpec(
            name: "station_doctor",
            category: "Diagnostics",
            summary: "Verifies Chrome binary, CDP WebSocket health, secondary tab pool, and 0600 token.",
            readOnly: true,
            exampleArgsJSON: "{}"
        ),
    ]

    public static let prompts: [MCPPromptSpec] = [
        MCPPromptSpec(
            name: "job_hunt_scan",
            title: "Job Hunt Scanner",
            summary: "Scans LinkedIn, Welcome to the Jungle, Wellfound & ATS boards in background tabs and ranks roles 0–100."
        ),
        MCPPromptSpec(
            name: "rent_listing_scan",
            title: "Rent & Housing Radar",
            summary: "Reads housing portals & logged-in groups, extracts price/area/phone, deduplicates, and filters noise."
        ),
        MCPPromptSpec(
            name: "authenticated_assist",
            title: "Human-in-the-Loop Form Assist",
            summary: "Pre-fills forms and attaches files via @eN refs, pausing cleanly before any final Submit button."
        ),
    ]
}
