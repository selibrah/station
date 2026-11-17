import Foundation
import ServiceManagement
import Combine

@MainActor
public final class AutoLaunchManager: ObservableObject {
    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var statusMessage: String = "Not registered"

    public static let shared = AutoLaunchManager()

    public init() {
        refresh()
    }

    public func refresh() {
        let status = SMAppService.mainApp.status
        self.isEnabled = (status == .enabled)
        switch status {
        case .enabled:
            self.statusMessage = "Enabled (Starts at login)"
        case .notRegistered:
            self.statusMessage = "Disabled"
        case .requiresApproval:
            self.statusMessage = "Requires approval in System Settings"
        case .notFound:
            self.statusMessage = "App bundle not found"
        @unknown default:
            self.statusMessage = "Unknown status"
        }
    }

    public func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            refresh()
        } catch {
            self.statusMessage = "Error: \(error.localizedDescription)"
        }
    }
}
