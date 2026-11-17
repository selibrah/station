import SwiftUI
import AppKit
import Charts
import StationCore

enum FindingsSubmode: String, CaseIterable, Identifiable {
    case pipeline = "Pipeline & CRM"
    case charts   = "Data Charts"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .pipeline: "list.bullet.indent"
        case .charts:   "chart.bar.xaxis"
        }
    }
}

enum FindingsSortOrder: String, CaseIterable, Identifiable {
    case score   = "Top Score"
    case newest  = "Newest"
    case lowest  = "Lowest Amount"
    case highest = "Highest Amount"

    var id: Self { self }
}

struct FindingsView: View {
    @ObservedObject var store: StationStore
    @ObservedObject var findings = FindingsStore.shared
    @Binding var selectedCategory: FindingCategory

    @State private var submode: FindingsSubmode = .pipeline
    @State private var stageFilter: String = "all"
    @State private var sourceFilter: String = "all"
    @State private var sortOrder: FindingsSortOrder = .score
    @State private var liveOnly: Bool = false
    @State private var searchQuery: String = ""
    @State private var selectedUID: String?
    @State private var draftNote: String = ""
    @State private var noteSavedFeedback: Bool = false
    @State private var showingAddSheet: Bool = false

    private var categorySubset: [FindingItem] {
        findings.filtered(category: selectedCategory, liveOnly: liveOnly)
    }

    private var availableSources: [String] {
        Array(Set(categorySubset.map(\.source))).sorted()
    }

    private var visibleItems: [FindingItem] {
        let base = findings.filtered(
            category: selectedCategory,
            stage: stageFilter,
            source: sourceFilter,
            query: searchQuery,
            liveOnly: liveOnly
        )
        return base.sorted { a, b in
            switch sortOrder {
            case .score:
                if a.score != b.score { return a.score > b.score }
                return a.firstSeen > b.firstSeen
            case .newest:
                return a.firstSeen > b.firstSeen
            case .lowest:
                return (a.amount ?? Int.max) < (b.amount ?? Int.max)
            case .highest:
                return (a.amount ?? 0) > (b.amount ?? 0)
            }
        }
    }

    private var selectedItem: FindingItem? {
        if let uid = selectedUID, let found = visibleItems.first(where: { $0.uid == uid }) {
            return found
        }
        return visibleItems.first
    }

    var body: some View {
        VStack(spacing: 0) {
            domainHeaderBar
            Divider()
            kpiSummaryStrip
            Divider()

            switch submode {
            case .pipeline:
                pipelineSplitView
            case .charts:
                chartsScrollView
            }
        }
        .onAppear {
            findings.reload()
            syncDraftNote()
        }
        .onChange(of: selectedItem?.uid) { _, _ in
            syncDraftNote()
        }
        .sheet(isPresented: $showingAddSheet) {
            AddFindingSheet(defaultCategory: selectedCategory == .all ? .jobs : selectedCategory) {
                findings.reload()
            }
        }
    }

    private func syncDraftNote() {
        draftNote = selectedItem?.note ?? ""
        noteSavedFeedback = false
    }

    // MARK: - Top Domain Switcher & Mode Toggle

    private var domainHeaderBar: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(FindingCategory.allCases) { cat in
                        let count = cat == .all
                            ? findings.items.count
                            : findings.items.filter { $0.category == cat }.count
                        let active = (selectedCategory == cat)

                        Button {
                            selectedCategory = cat
                            sourceFilter = "all"
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: cat.symbol)
                                    .font(.caption)
                                Text(cat.displayName)
                                    .font(.callout.weight(active ? .semibold : .regular))
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.caption2.monospacedDigit().weight(.semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(active ? Color.white.opacity(0.22) : Color.primary.opacity(0.08), in: Capsule())
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(active ? Color.white : Color.primary)
                            .background(active ? Color.accentColor : Color.primary.opacity(0.05), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 8)

            Picker("View", selection: $submode) {
                ForEach(FindingsSubmode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            Button {
                showingAddSheet = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Manually log an apartment, job, or lead")

            Button {
                findings.reload()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .help("Reload findings from SQLite databases")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Interactive KPI Summary Strip

    private var kpiSummaryStrip: some View {
        let subset = categorySubset
        let newCount = subset.filter { $0.status == "new" }.count
        let followUps = subset.filter(\.needsFollowUp).count
        let activePipeline = subset.filter { ["contacted", "replied", "visit"].contains($0.status) }.count
        let hist = findings.amountHistogram(for: subset)
        let medianText: String = {
            guard let med = hist.median else { return "—" }
            let grouped = NumberFormatter.localizedString(from: NSNumber(value: med), number: .decimal)
            return (hist.currency == "$" || hist.currency == "€") ? "\(hist.currency)\(grouped)" : "\(grouped) \(hist.currency)"
        }()

        return HStack(spacing: 10) {
            kpiTile(title: "Total Matched", value: "\(subset.count)", active: stageFilter == "all") {
                stageFilter = "all"
            }
            kpiTile(title: "Unreviewed (New)", value: "\(newCount)", tint: .blue, active: stageFilter == "new") {
                stageFilter = (stageFilter == "new") ? "all" : "new"
            }
            kpiTile(
                title: "In Pipeline",
                value: "\(activePipeline)",
                tint: .green,
                active: stageFilter == "contacted"
            ) {
                stageFilter = (stageFilter == "contacted") ? "all" : "contacted"
            }
            kpiTile(
                title: "Follow-Up Due",
                value: "\(followUps)",
                tint: followUps > 0 ? .orange : .secondary,
                active: stageFilter == "followup"
            ) {
                stageFilter = (stageFilter == "followup") ? "all" : "followup"
            }
            kpiTile(title: "Median Price / Comp", value: medianText, active: false, action: nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.02))
    }

    private func kpiTile(title: String, value: String, tint: Color = .primary, active: Bool, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(active ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    // MARK: - Mode 1: Pipeline & CRM Split View

    private var pipelineSplitView: some View {
        VStack(spacing: 0) {
            filterToolbar
            Divider()

            if visibleItems.isEmpty {
                emptyFindingsState
            } else {
                HSplitView {
                    List(visibleItems, selection: Binding(
                        get: { selectedItem?.uid },
                        set: { selectedUID = $0 }
                    )) { item in
                        findingListRow(item)
                            .tag(item.uid)
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 370, idealWidth: 450)

                    if let item = selectedItem {
                        findingDetailInspector(item)
                            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }

    private var filterToolbar: some View {
        HStack(spacing: 10) {
            TextField("Search title, district, company, skill, or note…", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            Picker("Stage", selection: $stageFilter) {
                Text("All Stages").tag("all")
                Text("Follow-Up Due").tag("followup")
                Divider()
                ForEach(FindingsStore.canonicalStages, id: \.self) { key in
                    Text(selectedCategory.stageLabel(for: key)).tag(key)
                }
            }
            .fixedSize()

            if availableSources.count > 1 {
                Picker("Source", selection: $sourceFilter) {
                    Text("All Sources").tag("all")
                    Divider()
                    ForEach(availableSources, id: \.self) { src in
                        Text(src.capitalized).tag(src)
                    }
                }
                .fixedSize()
            }

            Picker("Sort", selection: $sortOrder) {
                ForEach(FindingsSortOrder.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .fixedSize()

            Toggle("Active only", isOn: $liveOnly)
                .toggleStyle(.checkbox)
                .font(.callout)

            Spacer()

            Text("\(visibleItems.count) shown")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func findingListRow(_ item: FindingItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            scoreBadge(item.score)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if item.needsFollowUp {
                        Text("Follow up")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .foregroundStyle(.orange)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                }

                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.source.capitalized)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    stageBadge(status: item.status, category: item.category)
                    if !item.note.isEmpty {
                        Image(systemName: "note.text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(item.formattedAmount)
                    .font(.callout.monospacedDigit().weight(.semibold))
                Text(item.firstSeen.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .opacity(item.isLive || item.status != "new" ? 1.0 : 0.62)
    }

    private func findingDetailInspector(_ item: FindingItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Label(item.category.displayName, systemImage: item.category.symbol)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(item.source.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        scoreBadge(item.score)
                    }

                    Text(item.title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)

                    HStack(spacing: 12) {
                        if item.amount != nil {
                            Text(item.formattedAmount)
                                .font(.title3.monospacedDigit().weight(.bold))
                                .foregroundStyle(.primary)
                        }
                        Text(item.subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if !item.tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(item.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .foregroundStyle(.primary)
                                    .background(Color.primary.opacity(0.07), in: Capsule())
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                Divider()

                // Primary Actions (WhatsApp / Apply / Open in Station Tab)
                HStack(spacing: 8) {
                    if let cURL = item.contactURL, let urlObj = URL(string: cURL) {
                        Button {
                            NSWorkspace.shared.open(urlObj)
                        } label: {
                            Label(
                                item.contactLabel ?? "Contact",
                                systemImage: item.contactLabel == "WhatsApp" ? "message.fill" : "paperplane.fill"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(item.contactLabel == "WhatsApp" ? .green : .accentColor)
                    }

                    if !item.url.isEmpty {
                        Button {
                            if store.connectionStatus != .offline {
                                Task { await store.openTab(url: item.url, background: false) }
                            } else if let urlObj = URL(string: item.url) {
                                NSWorkspace.shared.open(urlObj)
                            }
                        } label: {
                            Label("Open in Station", systemImage: "macwindow.badge.plus")
                        }

                        CopyButton(text: item.url, title: "Copy Link")
                    }

                    Spacer()

                    Button(role: .destructive) {
                        findings.deleteFinding(uid: item.uid)
                    } label: {
                        Label(item.origin == .rentSeenDB ? "Drop" : "Delete", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .help(item.origin == .rentSeenDB ? "Mark listing as Dropped in seen.db" : "Delete from findings.db")
                }

                // 5-Stage CRM Pipeline Selector
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pipeline stage").cardTitle()
                    HStack(spacing: 6) {
                        ForEach(FindingsStore.canonicalStages, id: \.self) { stageKey in
                            let selected = (item.status == stageKey)
                            Button {
                                findings.updateFinding(uid: item.uid, status: stageKey)
                            } label: {
                                Text(item.category.stageLabel(for: stageKey))
                                    .font(.caption.weight(selected ? .semibold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity)
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                                    .background(selected ? stageColor(stageKey) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Personal Notes (Two-Way SQLite Sync)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Notes & follow-up").cardTitle()
                        Spacer()
                        if noteSavedFeedback {
                            Text("Saved to SQLite")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        if draftNote != item.note {
                            Button("Save Note") {
                                findings.updateFinding(uid: item.uid, note: draftNote)
                                noteSavedFeedback = true
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    TextEditor(text: $draftNote)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 68, maxHeight: 110)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                }

                // Full Listing / Job Excerpt
                VStack(alignment: .leading, spacing: 6) {
                    Text("Extracted details").cardTitle()
                    Text(item.snippet.isEmpty ? "No description text captured." : item.snippet)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }

                HStack {
                    Text("First seen: \(item.firstSeen.formatted(date: .abbreviated, time: .shortened))")
                    Spacer()
                    Text("Last matched: \(item.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Mode 2: Native Swift Charts & Analytics

    private var chartsScrollView: some View {
        let subset = categorySubset
        let funnel = findings.funnelCounts(for: subset, category: selectedCategory)
        let daily = findings.dailySeries(for: subset, days: 14)
        let hist = findings.amountHistogram(for: subset)
        let groups = findings.groupBreakdown(for: subset, limit: 8)
        let sources = findings.sourceBreakdown(for: subset)

        return ScrollView {
            if subset.isEmpty {
                emptyFindingsState
                    .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        funnelChartCard(funnel)
                        dailyVelocityCard(daily)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .top, spacing: 16) {
                        histogramCard(bins: hist.bins, median: hist.median, currency: hist.currency)
                        groupBreakdownCard(groups: groups, currency: hist.currency)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    sourceQualityCard(sources)
                }
                .padding(20)
                .frame(maxWidth: 1080)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func funnelChartCard(_ funnel: [StageBucket]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pipeline conversion funnel").cardTitle()
            Chart(funnel) { bucket in
                BarMark(
                    x: .value("Count", bucket.count),
                    y: .value("Stage", bucket.label)
                )
                .foregroundStyle(stageColor(bucket.key))
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    Text("\(bucket.count)")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 185)
            Text("Tracks progression from initial match to final outcome")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private func dailyVelocityCard(_ daily: [DailyBucket]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New findings · last 14 days").cardTitle()
            Chart(daily) { day in
                BarMark(
                    x: .value("Day", day.shortLabel),
                    y: .value("Found", day.count)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: 3))
            }
            .frame(height: 185)
            Text("Daily discovery volume across active watchers")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private func histogramCard(bins: [HistogramBin], median: Int?, currency: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Price / compensation distribution (\(currency.isEmpty ? "amount" : currency))").cardTitle()
                Spacer()
                if let median {
                    Text("Median: \(median) \(currency)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if bins.isEmpty {
                Text("No numeric prices or salaries extracted for this filter yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(height: 185)
            } else {
                Chart(bins) { bin in
                    BarMark(
                        x: .value("Range", bin.label),
                        y: .value("Listings", bin.count)
                    )
                    .foregroundStyle(Color.teal.gradient)
                    .cornerRadius(4)
                }
                .frame(height: 185)
            }
            Text("Auto-binned market distribution across matched items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private func groupBreakdownCard(groups: [GroupStatBucket], currency: String) -> some View {
        let heading = selectedCategory == .housing ? "Top districts & median rent" : "Top companies, areas & hosts"
        return VStack(alignment: .leading, spacing: 10) {
            Text(heading).cardTitle()
            Chart(groups) { grp in
                BarMark(
                    x: .value("Count", grp.count),
                    y: .value("Group", grp.name)
                )
                .foregroundStyle(Color.indigo.gradient)
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    if let med = grp.medianAmount {
                        Text("\(grp.count) · med \(med)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(grp.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 185)
            Text("Volume and median price/comp per neighborhood or organization")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private func sourceQualityCard(_ sources: [SourceStatBucket]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Source performance & signal quality").cardTitle()
            HStack(spacing: 12) {
                ForEach(sources) { src in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(src.source.capitalized)
                            .font(.subheadline.weight(.semibold))
                        Text("\(src.count) items")
                            .font(.title3.monospacedDigit().weight(.bold))
                        Text("Avg score: \(src.avgScore)/100")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
        .card()
    }

    // MARK: - Visual Helpers

    private var emptyFindingsState: some View {
        ContentUnavailableView {
            Label("No findings in \(selectedCategory.displayName)", systemImage: selectedCategory.symbol)
        } description: {
            Text("Run an Auto-Job (`⌘3`) such as Multi-Board Job Hunter or Lead Radar, or add an entry manually.")
        } actions: {
            HStack(spacing: 10) {
                Button("Add Manual Entry") { showingAddSheet = true }
                if stageFilter != "all" || !searchQuery.isEmpty || liveOnly {
                    Button("Clear Filters") {
                        stageFilter = "all"
                        sourceFilter = "all"
                        searchQuery = ""
                        liveOnly = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func scoreBadge(_ score: Int) -> some View {
        let color: Color = score >= 75 ? .green : (score >= 50 ? .blue : .secondary)
        return Text("\(score)")
            .font(.caption.monospacedDigit().weight(.bold))
            .frame(width: 30, height: 24)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
    }

    private func stageBadge(status: String, category: FindingCategory) -> some View {
        let c = stageColor(status)
        return Text(category.stageLabel(for: status))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(c)
            .background(c.opacity(0.13), in: Capsule())
    }

    private func stageColor(_ key: String) -> Color {
        switch key {
        case "new":       return .blue
        case "contacted": return .indigo
        case "replied":   return .teal
        case "visit":     return .green
        case "dropped":   return .secondary
        default:          return .secondary
        }
    }
}

// MARK: - Manual Entry Sheet

private struct AddFindingSheet: View {
    let defaultCategory: FindingCategory
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var category: FindingCategory = .jobs
    @State private var title: String = ""
    @State private var subtitle: String = ""
    @State private var amountText: String = ""
    @State private var currency: String = "$"
    @State private var url: String = ""
    @State private var snippet: String = ""

    var body: some View {
        Form {
            Picker("Category", selection: $category) {
                ForEach(FindingCategory.allCases.filter { $0 != .all }) { cat in
                    Text(cat.displayName).tag(cat)
                }
            }
            .onChange(of: category) { _, newCat in
                currency = (newCat == .housing || newCat == .deals) ? "DH" : "$"
            }

            TextField("Title (e.g. Senior Rust Engineer or Studio Maarif)", text: $title)
            TextField("Company / Neighborhood (e.g. Linear · Remote)", text: $subtitle)

            HStack {
                TextField("Price or Salary (optional)", text: $amountText)
                Picker("Currency", selection: $currency) {
                    Text("$").tag("$")
                    Text("DH").tag("DH")
                    Text("€").tag("€")
                }
                .frame(width: 100)
            }

            TextField("Listing / Posting URL", text: $url)
            TextField("Notes or Description", text: $snippet, axis: .vertical)
                .lineLimit(3...5)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear {
            category = defaultCategory
            currency = (defaultCategory == .housing || defaultCategory == .deals) ? "DH" : "$"
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save Finding") {
                    let amt = Int(amountText.filter(\.isNumber))
                    let extId = UUID().uuidString.prefix(12)
                    _ = FindingsStore.shared.upsertUniversalFinding(
                        category: category,
                        source: "manual",
                        externalId: String(extId),
                        title: title.trimmingCharacters(in: .whitespaces),
                        subtitle: subtitle.trimmingCharacters(in: .whitespaces),
                        amount: amt,
                        currency: currency,
                        score: 80,
                        tags: ["Manual"],
                        url: url.trimmingCharacters(in: .whitespaces),
                        contactURL: url.trimmingCharacters(in: .whitespaces),
                        contactLabel: "Open",
                        snippet: snippet
                    )
                    onSaved()
                    dismiss()
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
