import Foundation

public final class StationClient: StationRPCPort, @unchecked Sendable {
    private let stationBaseURL: URL
    private let session: URLSession

    public init(stationPort: Int = 19826) {
        self.stationBaseURL = URL(string: "http://127.0.0.1:\(stationPort)")!

        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 35.0
        config.connectionProxyDictionary = [:] // Avoid proxy & mDNS lookup overhead

        self.session = URLSession(configuration: config)
    }

    // MARK: - Station Daemon (19826)

    public func ping() async -> (ok: Bool, latencyMs: Double, arch: String?) {
        let info = await pingInfo()
        return (info.ok, info.latencyMs, info.arch)
    }

    public func pingInfo() async -> (ok: Bool, latencyMs: Double, arch: String?, version: String?, capabilities: [String]) {
        let url = stationBaseURL.appendingPathComponent("ping")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2.0

        let start = DispatchTime.now()
        do {
            let (data, response) = try await session.data(for: request)
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return (false, elapsedMs, nil, nil, [])
            }
            let pingRes = try? JSONDecoder().decode(PingResponseDTO.self, from: data)
            return (
                pingRes?.ok ?? false,
                (elapsedMs * 100).rounded() / 100,
                pingRes?.arch,
                pingRes?.version,
                pingRes?.capabilities ?? []
            )
        } catch {
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            return (false, elapsedMs, nil, nil, [])
        }
    }

    public func fetchDoctor(token: String) async -> Result<DoctorResponseDTO, Error> {
        let url = stationBaseURL.appendingPathComponent("doctor")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-Station-Token")

        do {
            let (data, _) = try await session.data(for: request)
            let decoded = try JSONDecoder().decode(DoctorResponseDTO.self, from: data)
            return .success(decoded)
        } catch {
            return .failure(error)
        }
    }

    public func fetchStatus(token: String) async -> Result<StationStatusResponseDTO, Error> {
        let url = stationBaseURL.appendingPathComponent("status")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-Station-Token")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NSError(domain: "StationClient", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
            }
            if http.statusCode == 401 {
                throw NSError(domain: "StationClient", code: 401, userInfo: [NSLocalizedDescriptionKey: "Unauthorized: Invalid or missing X-Station-Token"])
            }
            let decoded = try JSONDecoder().decode(StationStatusResponseDTO.self, from: data)
            return .success(decoded)
        } catch {
            return .failure(error)
        }
    }

    public func fetchTabs(token: String) async -> Result<[ChromeTargetDTO], Error> {
        let url = stationBaseURL.appendingPathComponent("tabs")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-Station-Token")

        do {
            let (data, _) = try await session.data(for: request)
            let decoded = try JSONDecoder().decode(TabsResponseDTO.self, from: data)
            if let tabs = decoded.tabs {
                return .success(tabs)
            }
            return .failure(NSError(domain: "StationClient", code: 500, userInfo: [NSLocalizedDescriptionKey: decoded.error ?? "No tabs returned"]))
        } catch {
            return .failure(error)
        }
    }

    public func executeCommand(request cmdReq: CommandRequestDTO, token: String) async -> Result<CommandResponseDTO, Error> {
        let url = stationBaseURL.appendingPathComponent("command")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Station-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(cmdReq)
            let (data, _) = try await session.data(for: request)
            let decoded = try JSONDecoder().decode(CommandResponseDTO.self, from: data)
            return .success(decoded)
        } catch {
            return .failure(error)
        }
    }

    public func fetchSnapshot(viewportOnly: Bool, session targetSession: String?, targetId: String?, token: String) async -> Result<SnapshotResponseDTO, Error> {
        let url = stationBaseURL.appendingPathComponent("snapshot")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Station-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["viewport_only": viewportOnly, "max_elements": 160]
        if let s = targetSession { body["session"] = s }
        if let t = targetId { body["target_id"] = t }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await session.data(for: request)
            let decoded = try JSONDecoder().decode(SnapshotResponseDTO.self, from: data)
            return .success(decoded)
        } catch {
            return .failure(error)
        }
    }

    public func performAct(request actReq: ActRequestDTO, token: String) async -> Result<CommandResponseDTO, Error> {
        let url = stationBaseURL.appendingPathComponent("act")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Station-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(actReq)
            let (data, _) = try await session.data(for: request)
            let decoded = try JSONDecoder().decode(CommandResponseDTO.self, from: data)
            return .success(decoded)
        } catch {
            return .failure(error)
        }
    }

    public func fetchRead(url targetURL: String?, session targetSession: String?, targetId: String?, token: String) async -> Result<ReadResponseDTO, Error> {
        let endpoint = stationBaseURL.appendingPathComponent("read")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Station-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20.0

        var body: [String: Any] = ["max_chars": 45000]
        if let u = targetURL, !u.isEmpty { body["url"] = u }
        if let s = targetSession { body["session"] = s }
        if let t = targetId { body["target_id"] = t }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await session.data(for: request)
            let decoded = try JSONDecoder().decode(ReadResponseDTO.self, from: data)
            return .success(decoded)
        } catch {
            return .failure(error)
        }
    }

    public func captureScreenshot(session targetSession: String?, targetId: String?, fullPage: Bool, token: String) async -> Result<ScreenshotResponseDTO, Error> {
        let url = stationBaseURL.appendingPathComponent("screenshot")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Station-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15.0

        var body: [String: Any] = ["format": "jpeg", "full_page": fullPage]
        if let s = targetSession { body["session"] = s }
        if let t = targetId { body["target_id"] = t }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await session.data(for: request)
            let decoded = try JSONDecoder().decode(ScreenshotResponseDTO.self, from: data)
            return .success(decoded)
        } catch {
            return .failure(error)
        }
    }

    public func navigate(url targetURL: String, newTab: Bool, background: Bool, session targetSession: String?, targetId: String?, token: String) async -> Result<Bool, Error> {
        let endpoint = stationBaseURL.appendingPathComponent("navigate")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Station-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["url": targetURL, "new_tab": newTab, "background": background]
        if let s = targetSession { body["session"] = s }
        if let t = targetId { body["target_id"] = t }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await session.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool {
                if ok { return .success(true) }
                let err = (json["error"] as? String) ?? "Navigation failed"
                return .failure(NSError(domain: "StationClient", code: 400, userInfo: [NSLocalizedDescriptionKey: err]))
            }
            return .success(true)
        } catch {
            return .failure(error)
        }
    }

    public func createTab(url targetURL: String, token: String) async -> Result<ChromeTargetDTO, Error> {
        await createTab(url: targetURL, background: false, token: token)
    }

    public func createTab(url targetURL: String, background: Bool, token: String) async -> Result<ChromeTargetDTO, Error> {
        let url = stationBaseURL.appendingPathComponent("tabs/new")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Station-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["url": targetURL, "background": background]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await session.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tabDict = json["tab"] as? [String: Any],
               let tabData = try? JSONSerialization.data(withJSONObject: tabDict) {
                let tab = try JSONDecoder().decode(ChromeTargetDTO.self, from: tabData)
                return .success(tab)
            }
            let errMsg = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String) ?? "Failed to parse created tab"
            return .failure(NSError(domain: "StationClient", code: 500, userInfo: [NSLocalizedDescriptionKey: errMsg]))
        } catch {
            return .failure(error)
        }
    }

    public func activateTab(targetId: String, token: String) async -> Result<Bool, Error> {
        let url = stationBaseURL.appendingPathComponent("tabs/activate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Station-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["target_id": targetId]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await session.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool {
                return .success(ok)
            }
            return .success(true)
        } catch {
            return .failure(error)
        }
    }

    public func closeTab(targetId: String, token: String) async -> Result<Bool, Error> {
        let url = stationBaseURL.appendingPathComponent("tabs/close")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Station-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["target_id": targetId]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await session.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ok = json["ok"] as? Bool {
                return .success(ok)
            }
            return .success(true)
        } catch {
            return .failure(error)
        }
    }
}
