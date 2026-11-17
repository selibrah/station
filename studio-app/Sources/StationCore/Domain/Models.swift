import Foundation

// MARK: - Core Domain Targets & States

public enum SessionTarget: String, Codable, Sendable, CaseIterable {
    case browser  = "browser"
    case gemini   = "gemini"
    case linkedin = "linkedin"
    case github   = "github"
    case colab    = "colab"
    case meta     = "meta"

    public var displayName: String {
        switch self {
        case .browser:  return "Main tab"
        case .gemini:   return "Gemini"
        case .linkedin: return "LinkedIn Jobs"
        case .github:   return "GitHub"
        case .colab:    return "Google Colab"
        case .meta:     return "Meta Ad Library"
        }
    }

    public var defaultURL: String {
        switch self {
        case .browser:  return "https://google.com"
        case .gemini:   return "https://gemini.google.com/app"
        case .linkedin: return "https://www.linkedin.com/jobs"
        case .github:   return "https://github.com"
        case .colab:    return "https://colab.research.google.com"
        case .meta:     return "https://www.facebook.com/ads/library"
        }
    }

    public var iconName: String {
        switch self {
        case .browser:  return "macwindow"
        case .gemini:   return "sparkles"
        case .linkedin: return "briefcase"
        case .github:   return "chevron.left.forwardslash.chevron.right"
        case .colab:    return "cpu"
        case .meta:     return "megaphone"
        }
    }
}

public enum ConnectionStatus: String, Codable, Sendable {
    case online
    case degraded
    case generating
    case offline
    case unauthorized
}

// MARK: - Station Token Model

public struct StationToken: Sendable, Equatable {
    public let rawValue: String
    public let loadedAt: Date
    public let path: String

    public init(rawValue: String, loadedAt: Date = Date(), path: String = "") {
        self.rawValue = rawValue
        self.loadedAt = loadedAt
        self.path = path
    }

    public var masked: String {
        guard rawValue.count >= 8 else { return "••••" }
        let prefix = rawValue.prefix(4)
        let suffix = rawValue.suffix(4)
        return "\(prefix)••••\(suffix)"
    }
}

// MARK: - Station Wire DTOs (19826)

public struct PingResponseDTO: Codable, Sendable {
    public let ok: Bool
    public let daemon: String?
    public let version: String?
    public let arch: String?
    public let capabilities: [String]?
}

/// `/status` payload. `url` and `title` come back for any page; Gemini tabs also include generation & login fields.
public struct StatusDataDTO: Codable, Sendable {
    public let chars: Int?
    public let isGenerating: Bool?
    public let isLoggedIn: Bool?
    public let readyState: String?
    public let title: String?
    public let url: String?
}

public struct StationStatusResponseDTO: Codable, Sendable {
    public let ok: Bool
    public let data: StatusDataDTO?
    public let error: String?
    public let latencyMs: Double?

    enum CodingKeys: String, CodingKey {
        case ok
        case data
        case error
        case latencyMs = "latency_ms"
    }
}

public struct ChromeTargetDTO: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let type: String
    public let url: String
    public let webSocketDebuggerUrl: String?
}

public struct TabsResponseDTO: Codable, Sendable {
    public let ok: Bool
    public let tabs: [ChromeTargetDTO]?
    public let mainHost: String?
    public let pooledSockets: Int?
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case tabs
        case mainHost = "main_host"
        case pooledSockets = "pooled_sockets"
        case error
    }
}

public struct CommandRequestDTO: Codable, Sendable {
    public let id: String
    public let action: String
    public let code: String?
    public let session: String?
    public let targetId: String?
    public let timeout: UInt64?

    enum CodingKeys: String, CodingKey {
        case id
        case action
        case code
        case session
        case targetId = "target_id"
        case timeout
    }

    public init(
        id: String = "cmd_\(Int(Date().timeIntervalSince1970 * 1000))",
        action: String = "exec",
        code: String? = nil,
        session: String? = "gemini",
        targetId: String? = nil,
        timeout: UInt64? = 30000
    ) {
        self.id = id
        self.action = action
        self.code = code
        self.session = session
        self.targetId = targetId
        self.timeout = timeout
    }
}

public struct CommandResponseDTO: Codable, Sendable {
    public let ok: Bool
    public let data: AnyCodableValue?
    public let error: String?
    public let latencyMs: Double?

    enum CodingKeys: String, CodingKey {
        case ok
        case data
        case error
        case latencyMs = "latency_ms"
    }
}

// MARK: - Snapshot, Act, Read, Screenshot & Doctor DTOs (v0.4)

public struct SnapshotElementDTO: Codable, Sendable, Identifiable, Equatable {
    public var id: String { ref }
    public let ref: String
    public let tag: String
    public let role: String
    public let label: String
    public let type: String?
    public let value: String?
    public let href: String?
    public let disabled: Bool?
    public let inViewport: Bool?

    enum CodingKeys: String, CodingKey {
        case ref, tag, role, label, type, value, href, disabled
        case inViewport = "in_viewport"
    }
}

public struct SnapshotHeadingDTO: Codable, Sendable, Equatable {
    public let level: String
    public let text: String
}

public struct SnapshotDataDTO: Codable, Sendable, Equatable {
    public let title: String
    public let url: String
    public let scrollY: Int
    public let maxScrollY: Int
    public let elementCount: Int
    public let headings: [SnapshotHeadingDTO]
    public let elements: [SnapshotElementDTO]
    public let snapshotText: String

    enum CodingKeys: String, CodingKey {
        case title, url, headings, elements
        case scrollY = "scroll_y"
        case maxScrollY = "max_scroll_y"
        case elementCount = "element_count"
        case snapshotText = "snapshot_text"
    }
}

public struct SnapshotResponseDTO: Codable, Sendable {
    public let ok: Bool
    public let data: SnapshotDataDTO?
    public let error: String?
    public let latencyMs: Double?

    enum CodingKeys: String, CodingKey {
        case ok, data, error
        case latencyMs = "latency_ms"
    }
}

public struct ActRequestDTO: Codable, Sendable {
    public let action: String
    public let target: String?
    public let value: String?
    public let session: String?
    public let targetId: String?

    enum CodingKeys: String, CodingKey {
        case action, target, value, session
        case targetId = "target_id"
    }

    public init(action: String, target: String? = nil, value: String? = nil, session: String? = nil, targetId: String? = nil) {
        self.action = action
        self.target = target
        self.value = value
        self.session = session
        self.targetId = targetId
    }
}

public struct ReadDataDTO: Codable, Sendable, Equatable {
    public let title: String
    public let url: String
    public let description: String?
    public let markdown: String
    public let markdownChars: Int
    public let rawHtmlChars: Int
    public let tokenSavingsPct: Double
    public let estimatedTokens: Int
    public let truncated: Bool?

    enum CodingKeys: String, CodingKey {
        case title, url, description, markdown, truncated
        case markdownChars = "markdown_chars"
        case rawHtmlChars = "raw_html_chars"
        case tokenSavingsPct = "token_savings_pct"
        case estimatedTokens = "estimated_tokens"
    }
}

public struct ReadResponseDTO: Codable, Sendable {
    public let ok: Bool
    public let data: ReadDataDTO?
    public let error: String?
    public let latencyMs: Double?

    enum CodingKeys: String, CodingKey {
        case ok, data, error
        case latencyMs = "latency_ms"
    }
}

public struct ScreenshotResponseDTO: Codable, Sendable {
    public let ok: Bool
    public let format: String?
    public let imageBase64: String?
    public let error: String?
    public let latencyMs: Double?

    enum CodingKeys: String, CodingKey {
        case ok, format, error
        case imageBase64 = "image_base64"
        case latencyMs = "latency_ms"
    }
}

public struct DoctorBrowserDTO: Codable, Sendable, Equatable {
    public let connected: Bool
    public let product: String?
    public let protocolVersion: String?
    public let binary: String?
    public let profileDir: String?

    enum CodingKeys: String, CodingKey {
        case connected, product, binary
        case protocolVersion = "protocol"
        case profileDir = "profile_dir"
    }
}

public struct DoctorCDPDTO: Codable, Sendable, Equatable {
    public let mainSocketHealthy: Bool
    public let evalLatencyMs: Double
    public let openPageTabs: Int
    public let pooledSecondarySockets: Int

    enum CodingKeys: String, CodingKey {
        case mainSocketHealthy = "main_socket_healthy"
        case evalLatencyMs = "eval_latency_ms"
        case openPageTabs = "open_page_tabs"
        case pooledSecondarySockets = "pooled_secondary_sockets"
    }
}

public struct DoctorMCPDTO: Codable, Sendable, Equatable {
    public let stdioSupported: Bool
    public let command: String
    public let tools: [String]

    enum CodingKeys: String, CodingKey {
        case stdioSupported = "stdio_supported"
        case command, tools
    }
}

public struct DoctorResponseDTO: Codable, Sendable, Equatable {
    public let ok: Bool
    public let browser: DoctorBrowserDTO?
    public let cdp: DoctorCDPDTO?
    public let mcp: DoctorMCPDTO?
    public let latencyMs: Double?

    enum CodingKeys: String, CodingKey {
        case ok, browser, cdp, mcp
        case latencyMs = "latency_ms"
    }
}

// MARK: - Telemetry & RPC Audit

public struct RPCLogEntry: Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let action: String
    public let session: String
    public let payloadSummary: String
    public let responseSummary: String
    public let latencyMs: Double
    public let isSuccess: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        action: String,
        session: String,
        payloadSummary: String,
        responseSummary: String,
        latencyMs: Double,
        isSuccess: Bool
    ) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
        self.session = session
        self.payloadSummary = payloadSummary
        self.responseSummary = responseSummary
        self.latencyMs = latencyMs
        self.isSuccess = isSuccess
    }
}

// MARK: - Flexible AnyCodableValue

public enum AnyCodableValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case dictionary([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([AnyCodableValue].self) {
            self = .array(arr)
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            self = .dictionary(dict)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .dictionary(let dict): try container.encode(dict)
        case .array(let arr): try container.encode(arr)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        default: return nil
        }
    }

    public var prettyJSON: String {
        switch self {
        case .string(let s): return s
        default:
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(self), let str = String(data: data, encoding: .utf8) {
                return str
            }
            return displayDescription
        }
    }

    public var displayDescription: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return "\(i)"
        case .double(let d): return String(format: "%.2f", d)
        case .bool(let b): return b ? "true" : "false"
        case .dictionary(let d):
            if let data = try? JSONEncoder().encode(d), let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{...}"
        case .array(let a):
            if let data = try? JSONEncoder().encode(a), let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "[...]"
        case .null: return "null"
        }
    }
}
