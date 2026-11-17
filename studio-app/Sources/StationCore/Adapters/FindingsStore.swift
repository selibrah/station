import Foundation
import Combine
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Universal Finding Domain Models

public enum FindingCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case all      = "all"
    case housing  = "housing"
    case jobs     = "jobs"
    case leads    = "leads"
    case deals    = "deals"
    case monitors = "monitors"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all:      return "All Jobs"
        case .housing:  return "Housing & Rent"
        case .jobs:     return "Job Search"
        case .leads:    return "Leads & Gigs"
        case .deals:    return "Deals & Arbitrage"
        case .monitors: return "Web Monitors"
        }
    }

    public var symbol: String {
        switch self {
        case .all:      return "square.grid.2x2"
        case .housing:  return "house"
        case .jobs:     return "briefcase"
        case .leads:    return "person.2.wave.2"
        case .deals:    return "tag"
        case .monitors: return "bell.badge"
        }
    }

    /// Maps canonical stage keys ("new", "contacted", "replied", "visit", "dropped") to domain-natural labels.
    public func stageLabel(for canonicalStatus: String) -> String {
        switch (self, canonicalStatus) {
        case (_, "new"):                return "New"
        case (.jobs, "contacted"):      return "Applied"
        case (.leads, "contacted"):     return "Pitched"
        case (.deals, "contacted"):     return "Messaged"
        case (.monitors, "contacted"):  return "Reviewed"
        case (_, "contacted"):          return "Contacted"

        case (.jobs, "replied"):        return "Interview"
        case (.deals, "replied"):       return "Negotiating"
        case (_, "replied"):            return "Replied"

        case (.jobs, "visit"):          return "Offer"
        case (.leads, "visit"):         return "Won"
        case (.deals, "visit"):         return "Bought"
        case (.monitors, "visit"):      return "Pinned"
        case (_, "visit"):              return "Visit"

        case (.jobs, "dropped"):        return "Archived"
        case (.leads, "dropped"):       return "Passed"
        case (_, "dropped"):            return "Dropped"
        default:                        return canonicalStatus.capitalized
        }
    }
}

public enum FindingOriginDB: Sendable, Equatable {
    case rentSeenDB
    case universalFindingsDB
}

public struct FindingItem: Identifiable, Equatable, Sendable {
    public let uid: String
    public var id: String { uid }
    public let origin: FindingOriginDB
    public let category: FindingCategory
    public let jobId: String
    public let source: String
    public let externalId: String
    public let title: String
    public let subtitle: String
    public let amount: Int?
    public let currency: String
    public let score: Int
    public let tags: [String]
    public let url: String
    public let contactURL: String?
    public let contactLabel: String?
    public let snippet: String
    public var status: String
    public var note: String
    public let firstSeen: Date
    public let lastSeen: Date
    public var statusAt: Date?
    public let isLive: Bool

    public var formattedAmount: String {
        guard let amount else { return "—" }
        let grouped = NumberFormatter.localizedString(from: NSNumber(value: amount), number: .decimal)
        if currency == "$" || currency == "€" || currency == "£" {
            return "\(currency)\(grouped)"
        }
        return "\(grouped) \(currency)"
    }

    public var needsFollowUp: Bool {
        guard status == "contacted", let at = statusAt else { return false }
        let thresholdHours: Double = (category == .jobs) ? 96 : 24
        return Date().timeIntervalSince(at) > thresholdHours * 3600
    }
}

// MARK: - Chart & Summary Aggregation Models

public struct StageBucket: Identifiable, Sendable, Equatable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let count: Int
}

public struct DailyBucket: Identifiable, Sendable, Equatable {
    public var id: String { day }
    public let day: String
    public let shortLabel: String
    public let count: Int
}

public struct HistogramBin: Identifiable, Sendable, Equatable {
    public var id: Int { from }
    public let from: Int
    public let to: Int
    public let label: String
    public let count: Int
}

public struct GroupStatBucket: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let count: Int
    public let medianAmount: Int?
}

public struct SourceStatBucket: Identifiable, Sendable, Equatable {
    public var id: String { source }
    public let source: String
    public let count: Int
    public let avgScore: Int
}

// MARK: - Native SQLite Findings & Analytics Store

@MainActor
public final class FindingsStore: ObservableObject {
    public static let shared = FindingsStore()

    public static let canonicalStages = ["new", "contacted", "replied", "visit", "dropped"]

    @Published public private(set) var items: [FindingItem] = []
    @Published public private(set) var lastLoadedAt: Date?

    public let universalDBPath: String
    public let rentFinderDir: String
    public var rentDBPath: String { (rentFinderDir as NSString).appendingPathComponent("seen.db") }

    public init(universalDBPath: String? = nil, rentFinderDir: String? = nil) {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        self.universalDBPath = universalDBPath
            ?? (home as NSString).appendingPathComponent(".flossi/agent_home/memory/findings.db")

        if let customRent = rentFinderDir {
            self.rentFinderDir = customRent
        } else {
            let bundleWorkspace = URL(fileURLWithPath: Bundle.main.bundlePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("rent-finder")
                .path
            let desktopWorkspace = (home as NSString).appendingPathComponent("Desktop/gemini-station-workspace/rent-finder")
            self.rentFinderDir = FileManager.default.fileExists(atPath: (bundleWorkspace as NSString).appendingPathComponent("seen.db"))
                ? bundleWorkspace
                : desktopWorkspace
        }

        ensureUniversalSchema()
        reload()
    }

    // MARK: - Reload From Both Databases

    public func reload() {
        var combined: [FindingItem] = []
        combined.append(contentsOf: loadRentSeenDB())
        combined.append(contentsOf: loadUniversalFindingsDB())

        combined.sort { a, b in
            if a.isLive != b.isLive { return a.isLive && !b.isLive }
            if a.score != b.score { return a.score > b.score }
            return a.firstSeen > b.firstSeen
        }

        self.items = combined
        self.lastLoadedAt = Date()
    }

    // MARK: - Two-Way CRM Updates (Status & Notes)

    public func updateFinding(uid: String, status: String? = nil, note: String? = nil) {
        guard let idx = items.firstIndex(where: { $0.uid == uid }) else { return }
        let target = items[idx]
        let newStatus = status ?? target.status
        let newNote = note ?? target.note
        let nowISO = Self.isoString(Date())

        switch target.origin {
        case .rentSeenDB:
            updateRentRow(source: target.source, id: target.externalId, status: status, note: note, nowISO: nowISO)
        case .universalFindingsDB:
            updateUniversalRow(uid: target.uid, status: status, note: note, nowISO: nowISO)
        }

        items[idx].status = newStatus
        items[idx].note = newNote
        if status != nil {
            items[idx].statusAt = Date()
        }
    }

    public func upsertUniversalFinding(
        category: FindingCategory,
        jobId: String = "",
        source: String,
        externalId: String,
        title: String,
        subtitle: String,
        amount: Int? = nil,
        currency: String = "$",
        score: Int = 65,
        tags: [String] = [],
        url: String,
        contactURL: String? = nil,
        contactLabel: String? = nil,
        snippet: String = ""
    ) -> Bool {
        ensureUniversalSchema()
        var db: OpaquePointer?
        guard sqlite3_open(universalDBPath, &db) == SQLITE_OK, let db else { return false }
        defer { sqlite3_close(db) }

        let uid = "\(category.rawValue):\(source):\(externalId)"
        var isNew = true
        var checkStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT 1 FROM findings WHERE uid=? LIMIT 1;", -1, &checkStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(checkStmt, 1, uid, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            if sqlite3_step(checkStmt) == SQLITE_ROW {
                isNew = false
            }
        }
        sqlite3_finalize(checkStmt)

        let sql = """
        INSERT INTO findings (
            uid, category, job_id, source, external_id, title, subtitle,
            amount, currency, score, tags_json, url, contact_url, contact_label,
            snippet, status, note, first_seen, last_seen, status_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'new', '', ?, ?, '')
        ON CONFLICT(uid) DO UPDATE SET
            score = excluded.score,
            amount = COALESCE(excluded.amount, findings.amount),
            tags_json = excluded.tags_json,
            snippet = CASE WHEN excluded.snippet != '' THEN excluded.snippet ELSE findings.snippet END,
            last_seen = excluded.last_seen;
        """

        let nowISO = Self.isoString(Date())
        let tagsData = (try? JSONSerialization.data(withJSONObject: tags)) ?? Data("[]".utf8)
        let tagsStr = String(data: tagsData, encoding: .utf8) ?? "[]"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, uid, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 2, category.rawValue, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 3, jobId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 4, source, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 5, externalId, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 6, title, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 7, subtitle, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        if let amount {
            sqlite3_bind_int64(stmt, 8, Int64(amount))
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        sqlite3_bind_text(stmt, 9, currency, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int(stmt, 10, Int32(score))
        sqlite3_bind_text(stmt, 11, tagsStr, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 12, url, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 13, contactURL ?? "", -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 14, contactLabel ?? "", -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 15, String(snippet.prefix(600)), -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 16, nowISO, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(stmt, 17, nowISO, -1, SQLITE_TRANSIENT_DESTRUCTOR)

        let rc = sqlite3_step(stmt)
        return rc == SQLITE_DONE && isNew
    }

    public func deleteFinding(uid: String) {
        guard let item = items.first(where: { $0.uid == uid }) else { return }
        if item.origin == .universalFindingsDB {
            var db: OpaquePointer?
            if sqlite3_open(universalDBPath, &db) == SQLITE_OK, let db {
                defer { sqlite3_close(db) }
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "DELETE FROM findings WHERE uid=?;", -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, uid, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                    _ = sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
            items.removeAll(where: { $0.uid == uid })
        } else {
            // For rent seen.db, mark dropped instead of deleting so rent_watch doesn't re-alert on next pass!
            updateFinding(uid: uid, status: "dropped")
        }
    }

    // MARK: - Analytics & Chart Builders

    public func filtered(category: FindingCategory, stage: String = "all", source: String = "all", query: String = "", liveOnly: Bool = false) -> [FindingItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            (category == .all || item.category == category)
                && (!liveOnly || item.isLive)
                && (stage == "all" || (stage == "followup" ? item.needsFollowUp : item.status == stage))
                && (source == "all" || item.source == source)
                && (q.isEmpty
                    || item.title.localizedCaseInsensitiveContains(q)
                    || item.subtitle.localizedCaseInsensitiveContains(q)
                    || item.snippet.localizedCaseInsensitiveContains(q)
                    || item.note.localizedCaseInsensitiveContains(q)
                    || item.tags.contains(where: { $0.localizedCaseInsensitiveContains(q) }))
        }
    }

    public func funnelCounts(for subset: [FindingItem], category: FindingCategory) -> [StageBucket] {
        Self.canonicalStages.map { key in
            StageBucket(
                key: key,
                label: category.stageLabel(for: key),
                count: subset.filter { $0.status == key }.count
            )
        }
    }

    public func dailySeries(for subset: [FindingItem], days: Int = 14) -> [DailyBucket] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dfKey = DateFormatter()
        dfKey.dateFormat = "yyyy-MM-dd"
        let dfShort = DateFormatter()
        dfShort.dateFormat = "MMM d"

        var countsByDay: [String: Int] = [:]
        for item in subset {
            let k = dfKey.string(from: item.firstSeen)
            countsByDay[k, default: 0] += 1
        }

        return (0..<days).reversed().compactMap { offset -> DailyBucket? in
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = dfKey.string(from: date)
            return DailyBucket(day: key, shortLabel: dfShort.string(from: date), count: countsByDay[key] ?? 0)
        }
    }

    public func amountHistogram(for subset: [FindingItem]) -> (bins: [HistogramBin], median: Int?, currency: String) {
        let priced = subset.compactMap { item -> (Int, String)? in
            guard let amt = item.amount, amt > 0 else { return nil }
            return (amt, item.currency)
        }
        guard !priced.isEmpty else { return ([], nil, "") }

        // Pick dominant currency so mixed "All Jobs" doesn't mix DH and USD in one histogram
        var currencyCounts: [String: Int] = [:]
        for (_, cur) in priced { currencyCounts[cur, default: 0] += 1 }
        let dominantCurrency = currencyCounts.max(by: { $0.value < $1.value })?.key ?? priced[0].1

        let values = priced.filter { $0.1 == dominantCurrency }.map(\.0).sorted()
        guard let first = values.first, let last = values.last else { return ([], nil, dominantCurrency) }

        let med = values[values.count / 2]
        let baseStep = first >= 10_000 ? 10_000 : 100
        let lo = (first / baseStep) * baseStep
        var step = baseStep
        while (last - lo) / step >= 10 {
            step *= 2
        }

        let binCount = max(1, (last - lo) / step + 1)
        var counts = [Int](repeating: 0, count: binCount)
        for v in values {
            let idx = min(binCount - 1, max(0, (v - lo) / step))
            counts[idx] += 1
        }

        let bins = (0..<binCount).map { i -> HistogramBin in
            let bFrom = lo + i * step
            let bTo = lo + (i + 1) * step - 1
            let lbl = bFrom >= 10_000 ? "\(bFrom / 1000)k" : "\(bFrom)"
            return HistogramBin(from: bFrom, to: bTo, label: lbl, count: counts[i])
        }
        return (bins, med, dominantCurrency)
    }

    public func groupBreakdown(for subset: [FindingItem], limit: Int = 10) -> [GroupStatBucket] {
        var groups: [String: [Int]] = [:]
        var rawCounts: [String: Int] = [:]

        for item in subset {
            let groupName = item.subtitle
                .components(separatedBy: "·")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = groupName.isEmpty ? item.source.capitalized : groupName
            rawCounts[key, default: 0] += 1
            if let amt = item.amount {
                groups[key, default: []].append(amt)
            }
        }

        return rawCounts.keys
            .map { key -> GroupStatBucket in
                let vals = (groups[key] ?? []).sorted()
                let med = vals.isEmpty ? nil : vals[vals.count / 2]
                return GroupStatBucket(name: key, count: rawCounts[key] ?? 0, medianAmount: med)
            }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.name < b.name
            }
            .prefix(limit)
            .map { $0 }
    }

    public func sourceBreakdown(for subset: [FindingItem]) -> [SourceStatBucket] {
        var map: [String: [Int]] = [:]
        for item in subset {
            map[item.source, default: []].append(item.score)
        }
        return map.map { source, scores in
            let avg = scores.isEmpty ? 0 : (scores.reduce(0, +) / scores.count)
            return SourceStatBucket(source: source, count: scores.count, avgScore: avg)
        }
        .sorted { $0.count > $1.count }
    }

    // MARK: - Private SQLite Readers & Writers

    private func ensureUniversalSchema() {
        let parent = (universalDBPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        var db: OpaquePointer?
        guard sqlite3_open(universalDBPath, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }

        let ddl = """
        CREATE TABLE IF NOT EXISTS findings (
            uid TEXT PRIMARY KEY,
            category TEXT NOT NULL,
            job_id TEXT DEFAULT '',
            source TEXT NOT NULL,
            external_id TEXT NOT NULL,
            title TEXT NOT NULL,
            subtitle TEXT DEFAULT '',
            amount INTEGER,
            currency TEXT DEFAULT '$',
            score INTEGER DEFAULT 50,
            tags_json TEXT DEFAULT '[]',
            url TEXT DEFAULT '',
            contact_url TEXT DEFAULT '',
            contact_label TEXT DEFAULT '',
            snippet TEXT DEFAULT '',
            status TEXT DEFAULT 'new',
            note TEXT DEFAULT '',
            first_seen TEXT NOT NULL,
            last_seen TEXT NOT NULL,
            status_at TEXT DEFAULT ''
        );
        """
        sqlite3_exec(db, ddl, nil, nil, nil)
    }

    private func loadUniversalFindingsDB() -> [FindingItem] {
        guard FileManager.default.fileExists(atPath: universalDBPath) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(universalDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT uid, category, job_id, source, external_id, title, subtitle, amount, currency,
               score, tags_json, url, contact_url, contact_label, snippet, status, note,
               first_seen, last_seen, status_at
        FROM findings;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var out: [FindingItem] = []
        let now = Date()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let uid = colText(stmt, 0)
            let catRaw = colText(stmt, 1)
            let category = FindingCategory(rawValue: catRaw) ?? .monitors
            let jobId = colText(stmt, 2)
            let source = colText(stmt, 3)
            let extId = colText(stmt, 4)
            let title = colText(stmt, 5)
            let subtitle = colText(stmt, 6)
            let amount: Int? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 7))
            let currency = colText(stmt, 8).isEmpty ? "$" : colText(stmt, 8)
            let score = Int(sqlite3_column_int(stmt, 9))
            let tagsJSON = colText(stmt, 10)
            let tags = (try? JSONSerialization.jsonObject(with: Data(tagsJSON.utf8)) as? [String]) ?? []
            let url = colText(stmt, 11)
            let cURL = colText(stmt, 12)
            let cLabel = colText(stmt, 13)
            let snippet = colText(stmt, 14)
            let status = colText(stmt, 15).isEmpty ? "new" : colText(stmt, 15)
            let note = colText(stmt, 16)
            let firstSeen = Self.parseISO(colText(stmt, 17)) ?? now
            let lastSeen = Self.parseISO(colText(stmt, 18)) ?? firstSeen
            let statusAt = Self.parseISO(colText(stmt, 19))
            let isLive = now.timeIntervalSince(lastSeen) < 7 * 24 * 3600

            out.append(FindingItem(
                uid: uid,
                origin: .universalFindingsDB,
                category: category,
                jobId: jobId,
                source: source,
                externalId: extId,
                title: title,
                subtitle: subtitle,
                amount: amount,
                currency: currency,
                score: score,
                tags: tags,
                url: url.hasPrefix("http") ? url : "",
                contactURL: cURL.hasPrefix("http") ? cURL : nil,
                contactLabel: cLabel.isEmpty ? nil : cLabel,
                snippet: snippet,
                status: status,
                note: note,
                firstSeen: firstSeen,
                lastSeen: lastSeen,
                statusAt: statusAt,
                isLive: isLive
            ))
        }
        return out
    }

    private func loadRentSeenDB() -> [FindingItem] {
        guard FileManager.default.fileExists(atPath: rentDBPath) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(rentDBPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }

        let (nearAreas, allAreas, placesKm, alsoAliases, priceMin, priceMax, msgTpl) = loadRentContext()

        let sql = """
        SELECT source, id, title, price, area, rooms, size, phone, url,
               first_seen, text, seller, last_seen, status, note, status_at
        FROM listings;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        var out: [FindingItem] = []
        let now = Date()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let source = colText(stmt, 0)
            let extId = colText(stmt, 1)
            let rawTitle = colText(stmt, 2)
            let price: Int? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 3))
            let rawArea = colText(stmt, 4)
            let rooms = colText(stmt, 5)
            let size = colText(stmt, 6)
            let phone = colText(stmt, 7)
            let url = colText(stmt, 8)
            let firstSeen = Self.parseISO(colText(stmt, 9)) ?? now
            let fullText = colText(stmt, 10)
            let seller = colText(stmt, 11)
            let lastSeenStr = colText(stmt, 12)
            let lastSeen = Self.parseISO(lastSeenStr) ?? firstSeen
            let status = colText(stmt, 13).isEmpty ? "new" : colText(stmt, 13)
            let note = colText(stmt, 14)
            let statusAt = Self.parseISO(colText(stmt, 15))

            let district = resolveRentDistrict(
                source: source,
                title: rawTitle,
                area: rawArea,
                text: fullText,
                areas: allAreas,
                alsoAliases: alsoAliases
            )
            let plainWhere = Self.plain(rawArea + " " + rawTitle + " " + fullText)
            let isNear = nearAreas.contains { Self.plain($0).count > 1 && plainWhere.contains(Self.plain($0)) }
            let km = placesKm[Self.plain(district)]
            let wa = Self.moroccanWhatsAppLink(
                phone: phone,
                message: msgTpl
                    .replacingOccurrences(of: "{title}", with: rawTitle)
                    .replacingOccurrences(of: "{price}", with: price.map(String.init) ?? "?")
                    .replacingOccurrences(of: "{area}", with: district)
                    .replacingOccurrences(of: "{source}", with: source.capitalized)
            )

            // Exact scoring logic matching dashboard.py
            var pts: Double = isNear ? 60 : (km == nil ? 10 : 10 + 14 * max(0, 1 - (km! / 15.0)))
            var tags: [String] = []
            if isNear { tags.append("Preferred Area") }
            if let price {
                if priceMax > priceMin {
                    let part = min(1.0, max(0.0, Double(priceMax - price) / Double(priceMax - priceMin)))
                    pts += 25.0 * part
                    if part >= 0.6 { tags.append("Great Price") }
                } else {
                    pts += 12.0
                }
            } else {
                pts += 8.0
            }
            if wa != nil {
                pts += 10.0
                tags.append("WhatsApp")
            }
            if now.timeIntervalSince(firstSeen) < 48 * 3600 {
                pts += 5.0
                tags.append("Fresh")
            }
            if seller == "PRIVATE" { tags.append("Particulier") }

            var subParts = [district]
            if !rooms.isEmpty { subParts.append("\(rooms) ch") }
            if !size.isEmpty { subParts.append("\(size) m²") }
            if let km { subParts.append(String(format: "%.1f km", km)) }

            let isLive = !lastSeenStr.isEmpty && now.timeIntervalSince(lastSeen) < 72 * 3600

            out.append(FindingItem(
                uid: "housing:\(source):\(extId)",
                origin: .rentSeenDB,
                category: .housing,
                jobId: "rent-watch",
                source: source,
                externalId: extId,
                title: rawTitle.isEmpty ? "Listing (\(district))" : rawTitle,
                subtitle: subParts.joined(separator: " · "),
                amount: price,
                currency: "DH",
                score: Int(pts.rounded()),
                tags: tags,
                url: url.hasPrefix("http") ? url : "",
                contactURL: wa,
                contactLabel: wa != nil ? "WhatsApp" : nil,
                snippet: fullText.isEmpty ? rawArea : String(fullText.prefix(500)),
                status: status,
                note: note,
                firstSeen: firstSeen,
                lastSeen: lastSeen,
                statusAt: statusAt,
                isLive: isLive
            ))
        }
        return out
    }

    private func updateRentRow(source: String, id: String, status: String?, note: String?, nowISO: String) {
        var db: OpaquePointer?
        guard sqlite3_open(rentDBPath, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }

        if let status {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE listings SET status=?, status_at=? WHERE source=? AND id=?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, status, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 2, nowISO, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 3, source, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 4, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        if let note {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE listings SET note=? WHERE source=? AND id=?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, String(note.prefix(500)), -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 2, source, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    private func updateUniversalRow(uid: String, status: String?, note: String?, nowISO: String) {
        var db: OpaquePointer?
        guard sqlite3_open(universalDBPath, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }

        if let status {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE findings SET status=?, status_at=? WHERE uid=?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, status, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 2, nowISO, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 3, uid, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        if let note {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE findings SET note=? WHERE uid=?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, String(note.prefix(500)), -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(stmt, 2, uid, -1, SQLITE_TRANSIENT_DESTRUCTOR)
                _ = sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Rent Metadata Helpers

    private func loadRentContext() -> (
        nearAreas: [String],
        allAreas: [String],
        placesKm: [String: Double],
        alsoAliases: [String: String],
        priceMin: Int,
        priceMax: Int,
        messageTpl: String
    ) {
        var nearAreas: [String] = []
        var allAreas: [String] = []
        var priceMin = 900
        var priceMax = 1400
        var msg = "Bonjour, je suis intéressé(e) par votre annonce « {title} » ({price} DH)."

        let cfgPath = (rentFinderDir as NSString).appendingPathComponent("config.json")
        let fallbackCfg = (rentFinderDir as NSString).appendingPathComponent("config.example.json")
        let useCfg = FileManager.default.fileExists(atPath: cfgPath) ? cfgPath : fallbackCfg
        if let data = try? Data(contentsOf: URL(fileURLWithPath: useCfg)),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let want = root["want"] as? [String: Any] {
                allAreas = (want["areas"] as? [String]) ?? []
                priceMin = (want["price_min"] as? Int) ?? priceMin
                priceMax = (want["price_max"] as? Int) ?? priceMax
            }
            if let urg = root["urgent"] as? [String: Any] {
                nearAreas = (urg["areas"] as? [String]) ?? []
            }
            if let m = root["message"] as? String { msg = m }
        }

        var placesKm: [String: Double] = [:]
        var alsoAliases: [String: String] = [:]
        let placesPath = (rentFinderDir as NSString).appendingPathComponent("places.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: placesPath)),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let places = root["places"] as? [String: [String: Any]] {
                for (k, v) in places {
                    if let km = v["km"] as? Double {
                        placesKm[Self.plain(k)] = km
                    }
                }
            }
            if let also = root["also"] as? [String: String] {
                for (k, v) in also {
                    alsoAliases[Self.plain(k)] = v
                }
            }
        }
        return (nearAreas, allAreas, placesKm, alsoAliases, priceMin, priceMax, msg)
    }

    private func resolveRentDistrict(
        source: String,
        title: String,
        area: String,
        text: String,
        areas: [String],
        alsoAliases: [String: String]
    ) -> String {
        let loose = (source == "facebook")
        let whereText = Self.plain(loose ? "\(title) \(text)" : area)
        for name in areas {
            let first = name.first
            let isPlace = (first?.isUppercase == true) || (first?.isASCII == false)
            if isPlace && whereText.contains(Self.plain(name)) {
                return name
            }
        }
        if loose {
            for (alias, canonical) in alsoAliases where whereText.contains(alias) {
                return canonical
            }
            return "Not stated"
        }
        let cleaned = area
            .replacingOccurrences(of: "Casablanca", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: ",", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Casablanca" : cleaned
    }

    private func colText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    private static func plain(_ s: String) -> String {
        let lower = s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return lower.folding(options: .diacriticInsensitive, locale: .current)
    }

    private static func moroccanWhatsAppLink(phone: String, message: String) -> String? {
        var digits = phone.filter(\.isNumber)
        if digits.hasPrefix("00") {
            digits = String(digits.dropFirst(2))
        } else if digits.hasPrefix("0") {
            digits = "212" + digits.dropFirst(1)
        }
        guard digits.count == 12, digits.hasPrefix("2126") || digits.hasPrefix("2127") else {
            return nil
        }
        let encoded = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return "https://wa.me/\(digits)?text=\(encoded)"
    }

    private static func isoString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: date)
    }

    private static func parseISO(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            f.dateFormat = fmt
            if let d = f.date(from: String(trimmed.prefix(19))) {
                return d
            }
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
