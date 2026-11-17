import Foundation

// MARK: - Auto-Agent Domain Models

public enum AgentRunStatus: String, Codable, CaseIterable {
    case active = "ACTIVE (24/7)"
    case paused = "PAUSED"
    case sleeping = "SLEEPING"
    case error = "ERROR"
}

public struct AgentMission: Identifiable, Codable, Equatable {
    public let id: String
    public var title: String
    public var goal: String
    public var intervalMinutes: Int
    public var status: String
    public var createdAt: String
    public var lastRunAt: String?
    public var lastResult: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case goal
        case intervalMinutes = "interval_minutes"
        case status
        case createdAt = "created_at"
        case lastRunAt = "last_run_at"
        case lastResult = "last_result"
    }

    public init(
        id: String,
        title: String,
        goal: String,
        intervalMinutes: Int = 15,
        status: String = "running",
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        lastRunAt: String? = nil,
        lastResult: String? = nil
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.intervalMinutes = intervalMinutes
        self.status = status
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.lastResult = lastResult
    }
}

public struct AgentTool: Identifiable, Codable, Equatable {
    public let id: String
    public var name: String
    public var filename: String
    public var description: String
    public var language: String
    public var executionCount: Int
    public var isVerified: Bool
    public var lastRunAt: String?
    public var status: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case filename
        case description
        case language
        case executionCount = "execution_count"
        case isVerified = "is_verified"
        case lastRunAt = "last_run_at"
        case status
    }

    public init(
        id: String,
        name: String,
        filename: String,
        description: String,
        language: String = "python",
        executionCount: Int = 0,
        isVerified: Bool = true,
        lastRunAt: String? = nil,
        status: String = "ready"
    ) {
        self.id = id
        self.name = name
        self.filename = filename
        self.description = description
        self.language = language
        self.executionCount = executionCount
        self.isVerified = isVerified
        self.lastRunAt = lastRunAt
        self.status = status
    }
}

public struct AgentActionLog: Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let actionType: String
    public let detail: String
    public let isSuccess: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        actionType: String,
        detail: String,
        isSuccess: Bool = true
    ) {
        self.id = id
        self.timestamp = timestamp
        self.actionType = actionType
        self.detail = detail
        self.isSuccess = isSuccess
    }
}

public struct AutoAgentConfigDTO: Codable {
    public var agentId: String
    public var name: String
    public var status: String
    public var heartbeatIntervalSeconds: Int
    public var maxDailyBudgetDollars: Double

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case name
        case status
        case heartbeatIntervalSeconds = "heartbeat_interval_seconds"
        case maxDailyBudgetDollars = "max_daily_budget_dollars"
    }
}
