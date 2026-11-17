import Foundation

// MARK: - Auth Credentials Port

public protocol AuthCredentialsPort: Sendable {
    func loadToken() throws -> StationToken
    func observeTokenChanges() -> AsyncStream<StationToken>
    func generateNewToken() throws -> StationToken
}

// MARK: - Station Daemon RPC Port (19826)

public protocol StationRPCPort: Sendable {
    func ping() async -> (ok: Bool, latencyMs: Double, arch: String?)
    func pingInfo() async -> (ok: Bool, latencyMs: Double, arch: String?, version: String?, capabilities: [String])
    func fetchDoctor(token: String) async -> Result<DoctorResponseDTO, Error>
    func fetchStatus(token: String) async -> Result<StationStatusResponseDTO, Error>
    func fetchTabs(token: String) async -> Result<[ChromeTargetDTO], Error>
    func executeCommand(request: CommandRequestDTO, token: String) async -> Result<CommandResponseDTO, Error>
    func fetchSnapshot(viewportOnly: Bool, session: String?, targetId: String?, token: String) async -> Result<SnapshotResponseDTO, Error>
    func performAct(request: ActRequestDTO, token: String) async -> Result<CommandResponseDTO, Error>
    func fetchRead(url: String?, session: String?, targetId: String?, token: String) async -> Result<ReadResponseDTO, Error>
    func captureScreenshot(session: String?, targetId: String?, fullPage: Bool, token: String) async -> Result<ScreenshotResponseDTO, Error>
    func navigate(url: String, newTab: Bool, background: Bool, session: String?, targetId: String?, token: String) async -> Result<Bool, Error>
    func createTab(url: String, token: String) async -> Result<ChromeTargetDTO, Error>
    func createTab(url: String, background: Bool, token: String) async -> Result<ChromeTargetDTO, Error>
    func activateTab(targetId: String, token: String) async -> Result<Bool, Error>
    func closeTab(targetId: String, token: String) async -> Result<Bool, Error>
}

// MARK: - Prompt Synthesizer Port (CSP TrustedHTML Safe)

public protocol PromptSynthesizerPort: Sendable {
    func synthesizeInjectionJS(prompt: String) -> String
    func synthesizeSendClickJS() -> String
    func synthesizeGenerationCheckJS() -> String
    func synthesizeResponseExtractJS() -> String
}
