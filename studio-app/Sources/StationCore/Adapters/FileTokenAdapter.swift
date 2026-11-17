import Foundation

public final class FileTokenAdapter: AuthCredentialsPort, @unchecked Sendable {
    private let tokenPath: String
    private let queue = DispatchQueue(label: "com.flossi.station.tokenwatcher", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var continuation: AsyncStream<StationToken>.Continuation?

    public init(customPath: String? = nil) {
        if let customPath = customPath {
            self.tokenPath = customPath
        } else {
            let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
            self.tokenPath = (home as NSString).appendingPathComponent(".flossi/station.token")
        }
    }

    deinit {
        stopWatching()
    }

    public func loadToken() throws -> StationToken {
        let url = URL(fileURLWithPath: tokenPath)
        guard FileManager.default.fileExists(atPath: tokenPath) else {
            throw NSError(domain: "FileTokenAdapter", code: 404, userInfo: [NSLocalizedDescriptionKey: "Token file not found at \(tokenPath)"])
        }
        let content = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count >= 16 else {
            throw NSError(domain: "FileTokenAdapter", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid token length in \(tokenPath)"])
        }
        return StationToken(rawValue: content, loadedAt: Date(), path: tokenPath)
    }

    public func generateNewToken() throws -> StationToken {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: "FileTokenAdapter", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to generate random bytes"])
        }
        let hexString = bytes.map { String(format: "%02x", $0) }.joined()

        let parentDir = (tokenPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let fileURL = URL(fileURLWithPath: tokenPath)
        try hexString.write(to: fileURL, atomically: true, encoding: .utf8)

        // Set POSIX permissions to 0600 (read/write by owner only)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath)

        let token = StationToken(rawValue: hexString, loadedAt: Date(), path: tokenPath)
        continuation?.yield(token)
        return token
    }

    public func observeTokenChanges() -> AsyncStream<StationToken> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.startWatching()

            // Yield current token immediately if available
            if let initial = try? self.loadToken() {
                continuation.yield(initial)
            }

            continuation.onTermination = { [weak self] _ in
                self?.stopWatching()
            }
        }
    }

    private func startWatching() {
        stopWatching()

        let fd = open(tokenPath, O_EVTONLY)
        guard fd >= 0 else {
            // File might not exist yet; schedule retry after short delay
            queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.startWatching()
            }
            return
        }
        self.fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let flags = src.data

            if flags.contains(.delete) || flags.contains(.rename) {
                // Atomic replace on CLI (e.g. rename tmp -> station.token) changed inode.
                // Re-bind watcher to new inode.
                self.stopWatching()
                self.queue.asyncAfter(deadline: .now() + 0.1) {
                    self.startWatching()
                }
            }

            if let updated = try? self.loadToken() {
                self.continuation?.yield(updated)
            }
        }

        src.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
                self?.fileDescriptor = -1
            }
        }

        self.source = src
        src.resume()
    }

    private func stopWatching() {
        if let src = source {
            src.cancel()
            source = nil
        }
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }
}
