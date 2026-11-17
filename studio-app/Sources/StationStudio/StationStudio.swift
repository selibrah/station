import SwiftUI
import AppKit
import StationCore

@main
struct StationStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = StationStore()
    @AppStorage("pane") private var pane: Pane = .overview

    var body: some Scene {
        Window("Station Studio", id: "main") {
            MainWindow(store: store)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandMenu("Navigate") {
                Button("Cockpit") { pane = .overview }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Findings & Charts") { pane = .findings }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Auto-Jobs") { pane = .agent }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Web Workbench") { pane = .playground }
                    .keyboardShortcut("4", modifiers: .command)
                Button("MCP Hub") { pane = .mcp }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Browser Tabs") { pane = .tabs }
                    .keyboardShortcut("6", modifiers: .command)
                Button("Activity Log") { pane = .activity }
                    .keyboardShortcut("7", modifiers: .command)
                Divider()
                Button("Settings") { pane = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra("Station Studio", systemImage: "antenna.radiowaves.left.and.right") {
            MenuBarView(store: store, selectedPane: $pane)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window leaves the app in the menu bar with 0% idle CPU.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
