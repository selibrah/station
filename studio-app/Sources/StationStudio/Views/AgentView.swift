import SwiftUI
import StationCore

struct AgentView: View {
    var onOpenFindings: ((FindingCategory) -> Void)? = nil

    @ObservedObject private var agent = AutoAgentManager.shared
    @ObservedObject private var findings = FindingsStore.shared
    @State private var addingMission = false
    @State private var missionToDelete: AgentMission?

    private var running: Bool { agent.runStatus == .active }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: running ? "play.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(running ? Color.green : Color.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(running ? "Scheduler Active" : "Scheduler Paused")
                            .font(.title3.weight(.semibold))
                        Text(heartbeatSummary)
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let onOpenFindings {
                        Button {
                            onOpenFindings(.all)
                        } label: {
                            Label("All Findings & Charts (\(findings.items.count))", systemImage: "chart.bar.doc.horizontal")
                        }
                    }
                    Button(running ? "Pause Scheduler" : "Resume Scheduler") {
                        agent.toggleRunStatus()
                    }
                }
                .padding(.vertical, 4)
            }

            Section("One-Click Auto-Job Templates") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(AutoAgentManager.templates) { tpl in
                        let catCount = findings.items.filter { $0.category == tpl.category }.count
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(tpl.title, systemImage: tpl.iconName)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(tpl.defaultIntervalMinutes)m")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(tpl.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                if let onOpenFindings, catCount > 0 {
                                    Button("\(catCount) Findings") {
                                        onOpenFindings(tpl.category)
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                }
                                Spacer()
                                Button("Add Job") {
                                    agent.addMission(
                                        title: tpl.title,
                                        goal: tpl.goal,
                                        intervalMinutes: tpl.defaultIntervalMinutes
                                    )
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if agent.missions.isEmpty {
                    Text("No scheduled Auto-Jobs yet. Pick a template above or add a custom job.")
                        .foregroundStyle(.secondary)
                }
                ForEach(agent.missions) { mission in
                    let isRunningNow = agent.runningMissionId == mission.id
                    let isPaused = mission.status != "running"
                    let cat = agent.inferCategory(for: mission)

                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(mission.title)
                                    .font(.body.weight(.medium))
                                Text(cat.displayName)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .foregroundStyle(Color.accentColor)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                                if isPaused {
                                    Text("Paused")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .foregroundStyle(.secondary)
                                        .background(Color.primary.opacity(0.08), in: Capsule())
                                }
                            }
                            Text(mission.goal)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let lastRes = mission.lastResult, !lastRes.isEmpty {
                                Text("Last run: \(lastRes)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 12)
                        Text("Every \(mission.intervalMinutes)m")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)

                        if let onOpenFindings {
                            Button("Results") {
                                onOpenFindings(cat)
                            }
                            .controlSize(.small)
                            .help("View findings, CRM pipeline, and charts for \(cat.displayName)")
                        }

                        Button {
                            Task { await agent.executeMission(id: mission.id) }
                        } label: {
                            if isRunningNow {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Run Now")
                            }
                        }
                        .controlSize(.small)
                        .disabled(agent.runningMissionId != nil)

                        Button {
                            agent.toggleMissionPause(id: mission.id)
                        } label: {
                            Image(systemName: isPaused ? "play" : "pause")
                        }
                        .buttonStyle(.borderless)
                        .help(isPaused ? "Resume schedule" : "Pause schedule")

                        Button {
                            missionToDelete = mission
                        } label: {
                            Label("Delete", systemImage: "trash").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this Auto-Job")
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                HStack {
                    Text("Scheduled Auto-Jobs")
                    Spacer()
                    Button("Custom Job", systemImage: "plus") { addingMission = true }
                        .buttonStyle(.borderless)
                }
            } footer: {
                Text("Every `url:https://...` or `script:...` job saves structured findings into SQLite (`seen.db` / `findings.db`) so you can manage statuses, notes, and Swift Charts in Findings & Charts (`⌘2`).")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Registered Python Tools") {
                if agent.tools.isEmpty {
                    Text("No tools registered in \(agent.toolsDir.path(percentEncoded: false)).")
                        .foregroundStyle(.secondary)
                }
                ForEach(agent.tools) { tool in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                                .font(.body.weight(.medium))
                            Text(tool.description)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(tool.filename) · \(tool.executionCount) runs")
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 12)
                        Button("Run") { Task { await agent.runToolScript(filename: tool.filename) } }
                            .controlSize(.small)
                    }
                }
            }

            Section("Execution Log") {
                ForEach(agent.actionLogs.prefix(40)) { log in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: log.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(log.isSuccess ? Color.green : Color.red)
                            .accessibilityLabel(log.isSuccess ? "Succeeded" : "Failed")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(log.detail)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Text(log.actionType.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Text(log.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $addingMission) {
            NewMissionSheet { title, goal, interval in
                agent.addMission(title: title, goal: goal, intervalMinutes: interval)
            }
        }
        .confirmationDialog(
            "Delete “\(missionToDelete?.title ?? "")”?",
            isPresented: Binding(get: { missionToDelete != nil }, set: { if !$0 { missionToDelete = nil } }),
            presenting: missionToDelete
        ) { mission in
            Button("Delete Auto-Job", role: .destructive) { agent.deleteMission(id: mission.id) }
        } message: { _ in
            Text("Removes this job from ~/.flossi/agent_home/memory/missions.json.")
        }
    }

    private var heartbeatSummary: String {
        var parts = ["Tick every \(agent.heartbeatIntervalSeconds) s", "\(agent.heartbeatCount) ticks"]
        if let last = agent.lastHeartbeatAt {
            parts.append("last \(last.formatted(date: .omitted, time: .standard))")
        }
        return parts.joined(separator: " · ")
    }
}

private struct NewMissionSheet: View {
    let onAdd: (String, String, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var goal = "url:https://"
    @State private var interval = 15

    var body: some View {
        Form {
            TextField("Job Title (e.g. Welcome to the Jungle Rust Roles)", text: $title)
            TextField("Target (`url:https://...` or `script:/path/to/watch.py`)", text: $goal, axis: .vertical)
                .font(.callout.monospaced())
                .lineLimit(2...5)
            Stepper("Run every \(interval) minutes", value: $interval, in: 5...1440, step: 5)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .navigationTitle("New Auto-Job")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save Job") {
                    onAdd(title.trimmingCharacters(in: .whitespaces), goal.trimmingCharacters(in: .whitespacesAndNewlines), interval)
                    dismiss()
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
