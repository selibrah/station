import Foundation
import Combine

/// Starts, restarts, and stops the local Rust `station` daemon directly from Station Studio.
@MainActor
public final class DaemonProcessManager: ObservableObject {
    public static let shared = DaemonProcessManager()

    @Published public var selectedProfile: String = "default"
    @Published public var standardWindow: Bool = true
    @Published public var initialURL: String = "about:blank"
    @Published public var customBinaryPath: String = ""
    @Published public private(set) var isLaunching: Bool = false
    @Published public private(set) var lastMessage: String?

    public let availableProfiles: [String] = ["default", "jobs", "rent", "gemini", "social"]

    public init() {}

    public var resolvedBinaryPath: String {
        MCPConfigurator.resolveStationBinary(customOverride: customBinaryPath.isEmpty ? nil : customBinaryPath)
    }

    public var binaryExists: Bool {
        FileManager.default.isExecutableFile(atPath: resolvedBinaryPath)
    }

    /// Spawns `station --force` as an independent background process and waits briefly for port 19826.
    public func startOrRestartDaemon(port: Int = 19826) async -> Bool {
        let bin = resolvedBinaryPath
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            lastMessage = "Station binary not found at \(bin)"
            return false
        }

        isLaunching = true
        lastMessage = "Starting Station (\(selectedProfile) profile)…"
        defer { isLaunching = false }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        var args = ["--port", "\(port)", "--force"]
        if standardWindow {
            args.append("--standard-window")
        }
        if selectedProfile == "gemini" {
            args.append("--gemini")
        } else {
            args.append(contentsOf: ["--profile-name", selectedProfile])
            if !initialURL.trimmingCharacters(in: .whitespaces).isEmpty {
                args.append(contentsOf: ["--url", initialURL])
            }
        }
        proc.arguments = args
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            lastMessage = "Failed to launch: \(error.localizedDescription)"
            return false
        }

        let client = StationClient(stationPort: port)
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let (ok, _, _) = await client.ping()
            if ok {
                lastMessage = "Station online on 127.0.0.1:\(port)"
                return true
            }
        }

        lastMessage = "Launched process, waiting for Chrome target…"
        return false
    }

    /// Gracefully stops a running `station` daemon on `port` (after verifying `/ping` answers `station`).
    public func stopDaemon(port: Int = 19826) async {
        let client = StationClient(stationPort: port)
        let info = await client.pingInfo()
        guard info.ok else {
            lastMessage = "Daemon is already stopped."
            return
        }

        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice

        do {
            try lsof.run()
            lsof.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for line in out.split(separator: "\n") {
                if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                    kill(pid, SIGTERM)
                }
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            lastMessage = "Stopped Station daemon."
        } catch {
            lastMessage = "Could not stop daemon: \(error.localizedDescription)"
        }
    }
}
