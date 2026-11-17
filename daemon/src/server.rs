use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use axum::{
    body::Bytes,
    extract::{Query, Request, State},
    http::StatusCode,
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use base64::Engine;
use colored::Colorize;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::browser::{session_pattern, BrowserManager};
use crate::cdp::{extract_eval_result, CdpClient, CdpTabPool};
use crate::dom::{self, ActParams};
use crate::gemini;

#[derive(Clone)]
pub struct AppState {
    pub cdp: Arc<CdpClient>,
    pub tab_pool: Arc<CdpTabPool>,
    pub browser_mgr: Arc<BrowserManager>,
    pub port: u16,
    pub token: Arc<String>,
    /// Host of the URL the daemon was started on; its tab owns the primary auto-reconnecting socket.
    pub main_host: Arc<str>,
}

/// True when a session pattern names the main tab's host ("linkedin.com" matches "www.linkedin.com").
fn is_main(main_host: &str, pat: &str) -> bool {
    !main_host.is_empty() && (main_host == pat || main_host.ends_with(&format!(".{}", pat)))
}

/// Resolves the persistent `CdpClient` for `target_id` or `session` (uses `tab_pool` for secondary tabs).
pub async fn client_for(
    state: &AppState,
    target_id: Option<&str>,
    session: Option<&str>,
) -> Result<Arc<CdpClient>, String> {
    if let Some(tid) = target_id.filter(|s| !s.trim().is_empty()) {
        let target = state.browser_mgr.resolve_strict_target(Some(tid), None).await?;
        let ws = target.websocket_debugger_url.ok_or_else(|| "Tab has no debugger WebSocket URL".to_string())?;
        return state.tab_pool.get_or_connect(&target.id, &ws).await;
    }
    if let Some(s) = session.filter(|s| !s.trim().is_empty()) {
        let pat = session_pattern(s);
        if !is_main(&state.main_host, &pat) {
            let target = state.browser_mgr.resolve_strict_target(None, Some(s)).await?;
            let ws = target.websocket_debugger_url.ok_or_else(|| "Tab has no debugger WebSocket URL".to_string())?;
            return state.tab_pool.get_or_connect(&target.id, &ws).await;
        }
    }
    Ok(Arc::clone(&state.cdp))
}

/// Runs JS in the tab for `session` (kept compatible with `gemini.rs`).
pub async fn eval_session(
    state: &AppState,
    session: Option<&str>,
    code: &str,
    timeout: u64,
) -> Result<Value, String> {
    let client = client_for(state, None, session).await?;
    client.eval_js(code, timeout).await
}

/// Runs JS in the tab selected by `target_id` or `session`.
pub async fn eval_target(
    state: &AppState,
    target_id: Option<&str>,
    session: Option<&str>,
    code: &str,
    timeout: u64,
) -> Result<Value, String> {
    let client = client_for(state, target_id, session).await?;
    client.eval_js(code, timeout).await
}

/// Runs any raw DevTools method on the tab selected by `target_id` or `session`.
async fn raw_target(
    state: &AppState,
    target_id: Option<&str>,
    session: Option<&str>,
    method: &str,
    params: Value,
    timeout: u64,
) -> Result<Value, String> {
    let client = client_for(state, target_id, session).await?;
    let resp = client.send_raw_command(method, params, timeout).await?;
    if let Some(err) = resp.get("error") {
        Err(err.get("message").and_then(|m| m.as_str()).unwrap_or("CDP error").to_string())
    } else if method == "Runtime.evaluate" {
        extract_eval_result(&resp)
    } else {
        Ok(resp.get("result").cloned().unwrap_or(resp))
    }
}

/// url and title of a tab; on a Gemini tab also isGenerating, chars and isLoggedIn.
pub async fn page_status(cdp: &CdpClient) -> Result<Value, String> {
    let page = cdp.eval_js("({ url: location.href, title: document.title, readyState: document.readyState })", 5000).await?;
    if page.get("url").and_then(|u| u.as_str()).is_some_and(|u| u.contains(gemini::HOST)) {
        return cdp.eval_js(gemini::STATUS_JS, 5000).await;
    }
    Ok(page)
}

/// Every request except /ping must carry this header with the token from ~/.flossi/station.token.
pub const TOKEN_HEADER: &str = "X-Station-Token";

/// Reported by /ping; `--force` only replaces a process that answers with this (or the old name).
pub const DAEMON_NAME: &str = "station";
pub const OLD_DAEMON_NAME: &str = "gemini-station";

pub fn token_path() -> PathBuf {
    if let Ok(custom) = std::env::var("STATION_TOKEN_FILE") {
        if !custom.trim().is_empty() {
            return PathBuf::from(custom);
        }
    }
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(".flossi").join("station.token")
}

/// Reuses the saved token so clients keep working across restarts; creates one (mode 600 on Unix) on first run.
pub fn load_or_create_token() -> std::io::Result<String> {
    let path = token_path();
    if let Ok(t) = std::fs::read_to_string(&path) {
        if t.trim().len() >= 32 {
            return Ok(t.trim().to_string());
        }
    }
    let token = generate_random_hex_token()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&path)?;
        std::io::Write::write_all(&mut f, token.as_bytes())?;
    }
    #[cfg(not(unix))]
    {
        std::fs::write(&path, token.as_bytes())?;
    }
    Ok(token)
}

fn generate_random_hex_token() -> std::io::Result<String> {
    let mut bytes = [0u8; 32];
    #[cfg(unix)]
    {
        use std::io::Read;
        std::fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    }
    #[cfg(not(unix))]
    {
        use std::collections::hash_map::RandomState;
        use std::hash::{BuildHasher, Hasher};
        for chunk in bytes.chunks_mut(8) {
            let h = RandomState::new().build_hasher().finish().to_le_bytes();
            for (dst, src) in chunk.iter_mut().zip(h.iter()) {
                *dst = *src;
            }
        }
    }
    Ok(bytes.iter().map(|b| format!("{:02x}", b)).collect())
}

async fn require_token(State(state): State<AppState>, req: Request, next: Next) -> Response {
    if req.uri().path() == "/ping" {
        return next.run(req).await;
    }
    let given = req.headers().get(TOKEN_HEADER).and_then(|v| v.to_str().ok()).unwrap_or("");
    let expected = state.token.as_bytes();
    let ok = given.len() == expected.len()
        && given.bytes().zip(expected).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0;
    if !ok {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "ok": false, "error": "missing or wrong X-Station-Token" })),
        )
            .into_response();
    }
    next.run(req).await
}

/// Only plain web pages; blocks javascript:, file:, chrome: and data: URLs.
pub fn check_url(url: &str) -> Result<(), String> {
    let lower = url.trim().to_ascii_lowercase();
    if lower.starts_with("https://") || lower.starts_with("http://") {
        Ok(())
    } else {
        Err(format!(
            "Only http(s) URLs are allowed, got: {}",
            url.chars().take(40).collect::<String>()
        ))
    }
}

#[derive(Debug, Default, Deserialize)]
pub struct TargetQuery {
    pub session: Option<String>,
    pub target_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
pub struct CommandRequest {
    pub id: Option<String>,
    pub action: Option<String>,
    pub code: Option<String>,
    pub method: Option<String>,
    pub params: Option<Value>,
    pub session: Option<String>,
    pub target_id: Option<String>,
    #[serde(rename = "contextId")]
    pub context_id: Option<String>,
    pub timeout: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct CommandResponse {
    pub ok: bool,
    pub data: Option<Value>,
    pub error: Option<String>,
    pub latency_ms: f64,
}

#[derive(Debug, Deserialize)]
pub struct InjectRequest {
    pub prompt: String,
    pub auto_send: Option<bool>,
    pub session: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct NavigateRequest {
    pub url: String,
    pub new_tab: Option<bool>,
    pub background: Option<bool>,
    pub session: Option<String>,
    pub target_id: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
pub struct ScreenshotRequest {
    pub format: Option<String>,
    pub full_page: Option<bool>,
    pub session: Option<String>,
    pub target_id: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
pub struct SnapshotRequest {
    pub viewport_only: Option<bool>,
    pub max_elements: Option<usize>,
    pub session: Option<String>,
    pub target_id: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
pub struct ReadRequest {
    pub url: Option<String>,
    pub max_chars: Option<usize>,
    pub wait_ms: Option<u64>,
    pub session: Option<String>,
    pub target_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct UploadRequest {
    pub files: Vec<String>,
    pub selector: Option<String>,
    pub session: Option<String>,
    pub target_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct TabActionRequest {
    pub target_id: String,
}

pub fn create_router(state: AppState) -> Router {
    // No CORS layer on purpose: web pages must not be able to read from or drive this daemon.
    Router::new()
        .route("/ping", get(ping_handler))
        .route("/doctor", get(doctor_handler))
        .route("/status", get(status_handler))
        .route("/tabs", get(tabs_handler))
        .route("/navigate", post(navigate_handler))
        .route("/screenshot", post(screenshot_handler))
        .route("/snapshot", post(snapshot_handler))
        .route("/act", post(act_handler))
        .route("/read", post(read_handler))
        .route("/upload", post(upload_handler))
        .route("/tabs/new", post(new_tab_handler))
        .route("/tabs/activate", post(activate_tab_handler))
        .route("/tabs/close", post(close_tab_handler))
        .route("/command", post(command_handler))
        .route("/inject", post(inject_handler))
        .layer(middleware::from_fn_with_state(state.clone(), require_token))
        .with_state(state)
}

fn arch_label() -> String {
    if cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        "rust-native-apple-silicon".to_string()
    } else {
        format!("rust-native-{}-{}", std::env::consts::OS, std::env::consts::ARCH)
    }
}

async fn ping_handler() -> impl IntoResponse {
    let resp = json!({
        "ok": true,
        "daemon": DAEMON_NAME,
        "version": env!("CARGO_PKG_VERSION"),
        "arch": arch_label(),
        "capabilities": ["cdp-pool", "snapshot", "act", "read", "upload", "mcp", "doctor"],
    });
    (StatusCode::OK, Json(resp))
}

async fn doctor_handler(State(state): State<AppState>) -> impl IntoResponse {
    let start = Instant::now();
    let chrome_bin = BrowserManager::find_chrome_binary().ok().map(|p| p.display().to_string());
    let version = state.browser_mgr.version_info().await.ok();
    let tabs = state.browser_mgr.get_all_targets().await.unwrap_or_default();
    let pooled = state.tab_pool.active_count().await;
    let cdp_eval_start = Instant::now();
    let cdp_ok = state.cdp.eval_js("1 + 1", 2000).await.is_ok();
    let cdp_latency_ms = (cdp_eval_start.elapsed().as_secs_f64() * 1000.0 * 100.0).round() / 100.0;

    let tok_path = token_path();
    let tok_exists = tok_path.exists();

    let all_healthy = version.is_some() && cdp_ok && tok_exists;
    let elapsed = (start.elapsed().as_secs_f64() * 1000.0 * 100.0).round() / 100.0;

    (
        StatusCode::OK,
        Json(json!({
            "ok": all_healthy,
            "daemon": {
                "name": DAEMON_NAME,
                "version": env!("CARGO_PKG_VERSION"),
                "arch": arch_label(),
                "http_port": state.port,
                "cdp_port": state.browser_mgr.cdp_port,
                "main_host": state.main_host.as_ref(),
            },
            "browser": {
                "connected": version.is_some(),
                "product": version.as_ref().map(|v| v.browser.clone()),
                "protocol": version.as_ref().map(|v| v.protocol_version.clone()),
                "binary": chrome_bin,
                "profile_dir": state.browser_mgr.profile_dir.display().to_string(),
            },
            "cdp": {
                "main_socket_healthy": cdp_ok,
                "eval_latency_ms": cdp_latency_ms,
                "open_page_tabs": tabs.len(),
                "pooled_secondary_sockets": pooled,
            },
            "auth": {
                "token_file": tok_path.display().to_string(),
                "token_present": tok_exists,
            },
            "mcp": {
                "stdio_supported": true,
                "command": "station mcp --auto-start",
                "tools": [
                    "station_status", "station_tabs", "station_navigate",
                    "station_snapshot", "station_act", "station_read",
                    "station_upload", "station_eval", "station_screenshot",
                    "station_inject", "station_doctor"
                ]
            },
            "latency_ms": elapsed
        })),
    )
}

async fn status_handler(
    State(state): State<AppState>,
    Query(query): Query<TargetQuery>,
) -> impl IntoResponse {
    let start = Instant::now();
    let cdp = match client_for(&state, query.target_id.as_deref(), query.session.as_deref()).await {
        Ok(c) => c,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "ok": false, "error": e, "latency_ms": 0.0 })),
            );
        }
    };
    let status_val = page_status(&cdp).await;
    let elapsed = (start.elapsed().as_secs_f64() * 1000.0 * 100.0).round() / 100.0;

    match status_val {
        Ok(data) => (
            StatusCode::OK,
            Json(json!({
                "ok": true,
                "data": data,
                "latency_ms": elapsed,
            })),
        ),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({
                "ok": false,
                "error": e,
                "latency_ms": elapsed,
            })),
        ),
    }
}

async fn tabs_handler(State(state): State<AppState>) -> impl IntoResponse {
    let pooled = state.tab_pool.active_count().await;
    match state.browser_mgr.get_all_targets().await {
        Ok(targets) => (
            StatusCode::OK,
            Json(json!({
                "ok": true,
                "tabs": targets,
                "main_host": state.main_host.as_ref(),
                "pooled_sockets": pooled,
            })),
        ),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}

async fn navigate_handler(
    State(state): State<AppState>,
    Json(payload): Json<NavigateRequest>,
) -> impl IntoResponse {
    let start = Instant::now();
    if let Err(e) = check_url(&payload.url) {
        return (StatusCode::BAD_REQUEST, Json(json!({ "ok": false, "error": e })));
    }
    if payload.new_tab.unwrap_or(false) {
        let bg = payload.background.unwrap_or(false);
        match state.browser_mgr.create_tab_opts(&payload.url, bg, Some(&state.cdp)).await {
            Ok(target) => (
                StatusCode::OK,
                Json(json!({
                    "ok": true,
                    "target": target,
                    "latency_ms": (start.elapsed().as_secs_f64() * 1000.0 * 100.0).round() / 100.0,
                })),
            ),
            Err(e) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "ok": false, "error": e })),
            ),
        }
    } else {
        let client = match client_for(&state, payload.target_id.as_deref(), payload.session.as_deref()).await {
            Ok(c) => c,
            Err(e) => return (StatusCode::BAD_REQUEST, Json(json!({ "ok": false, "error": e }))),
        };
        match client.navigate(&payload.url).await {
            Ok(val) => (
                StatusCode::OK,
                Json(json!({
                    "ok": true,
                    "result": val,
                    "latency_ms": (start.elapsed().as_secs_f64() * 1000.0 * 100.0).round() / 100.0,
                })),
            ),
            Err(e) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "ok": false, "error": e })),
            ),
        }
    }
}

async fn screenshot_handler(State(state): State<AppState>, body: Bytes) -> impl IntoResponse {
    let start = Instant::now();
    let req: ScreenshotRequest = if body.is_empty() {
        ScreenshotRequest::default()
    } else {
        serde_json::from_slice(&body).unwrap_or_default()
    };
    let fmt = req.format.as_deref().unwrap_or("png");
    let full_page = req.full_page.unwrap_or(false);

    let client = match client_for(&state, req.target_id.as_deref(), req.session.as_deref()).await {
        Ok(c) => c,
        Err(e) => return (StatusCode::BAD_REQUEST, Json(json!({ "ok": false, "error": e }))),
    };

    match client.capture_screenshot_opts(fmt, full_page).await {
        Ok(b64) => (
            StatusCode::OK,
            Json(json!({
                "ok": true,
                "format": if fmt.eq_ignore_ascii_case("jpg") || fmt.eq_ignore_ascii_case("jpeg") { "jpeg" } else if fmt.eq_ignore_ascii_case("webp") { "webp" } else { "png" },
                "image_base64": b64,
                "latency_ms": (start.elapsed().as_secs_f64() * 1000.0 * 100.0).round() / 100.0,
            })),
        ),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}

async fn snapshot_handler(State(state): State<AppState>, body: Bytes) -> impl IntoResponse {
    let start = Instant::now();
    let req: SnapshotRequest = if body.is_empty() {
        SnapshotRequest::default()
    } else {
        serde_json::from_slice(&body).unwrap_or_default()
    };
    let js = dom::build_snapshot_js(req.viewport_only.unwrap_or(false), req.max_elements.unwrap_or(120));
    match eval_target(&state, req.target_id.as_deref(), req.session.as_deref(), &js, 15000).await {
        Ok(val) => (
            StatusCode::OK,
            Json(json!({
                "ok": true,
                "data": val,
                "latency_ms": (start.elapsed().as_secs_f64() * 1000.0 * 100.0).round() / 100.0,
            })),
        ),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}

async fn act_handler(
    State(state): State<AppState>,
    Json(params): Json<ActParams>,
) -> impl IntoResponse {
    let start = Instant::now();
    let js = dom::build_act_js(&params);
    match eval_target(&state, params.target_id.as_deref(), params.session.as_deref(), &js, 15000).await {
        Ok(val) => {
            let inner_ok = val.get("ok").and_then(|b| b.as_bool()).unwrap_or(true);
            let inner_err = val.get("error").and_then(|s| s.as_str()).map(String::from);
            (
                StatusCode::OK,
                Json(json!({
                    "ok": inner_ok,
                    "data": val,
                    "error": inner_err,
                    "latency_ms": (start.elapsed().as_secs_f64() * 1000.0 * 100.0).round() / 100.0,
                })),
            )
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}

async fn read_handler(State(state): State<AppState>, body: Bytes) -> impl IntoResponse {
    let start = Instant::now();
    let req: ReadRequest = if body.is_empty() {
        ReadRequest::default()
    } else {
        serde_json::from_slice(&body).unwrap_or_default()
    };
    let max_chars = req.max_chars.unwrap_or(40_000);
    let js = dom::build_read_js(max_chars);

    // Optional ephemeral background URL read: opens URL in background tab, waits for load, extracts Markdown, closes tab.
    if let Some(ref url) = req.url.as_ref().filter(|u| !u.trim().is_empty()) {
        if let Err(e) = check_url(url) {
            return (StatusCode::BAD_REQUEST, Json(json!({ "ok": false, "error": e })));
        }
        let created = match state.browser_mgr.create_tab_opts(url, true, Some(&state.cdp)).await {
            Ok(t) => t,
            Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "ok": false, "error": e }))),
        };
        let wait_budget = Duration::from_millis(req.wait_ms.unwrap_or(2200).clamp(200, 15000));
        let poll_start = Instant::now();
        while poll_start.elapsed() < wait_budget {
            tokio::time::sleep(Duration::from_millis(250)).await;
            if let Ok(state_val) = eval_target(&state, Some(&created.id), None, "document.readyState", 2000).await {
                if state_val.as_str() == Some("complete") {
                    // Brief settle window for SPA hydration
                    tokio::time::sleep(Duration::from_millis(350)).await;
                    break;
                }
            }
        }
        let read_res = eval_target(&state, Some(&created.id), None, &js, 15000).await;
        state.tab_pool.remove(&created.id).await;
        let _ = state.browser_mgr.close_tab(&created.id).await;

        return match read_res {
            Ok(val) => (
                StatusCode::OK,
                Json(json!({
                    "ok": true,
                    "data": val,
                    "latency_ms": (start.elapsed().as_secs_f64() * 1000.0 * 100.0).round() / 100.0,
                })),
            ),
            Err(e) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "ok": false, "error": e })),
            ),
        };
    }

    match eval_target(&state, req.target_id.as_deref(), req.session.as_deref(), &js, 15000).await {
        Ok(val) => (
            StatusCode::OK,
            Json(json!({
                "ok": true,
                "data": val,
                "latency_ms": (start.elapsed().as_secs_f64() * 1000.0 * 100.0).round() / 100.0,
            })),
        ),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}

async fn upload_handler(
    State(state): State<AppState>,
    Json(req): Json<UploadRequest>,
) -> impl IntoResponse {
    let start = Instant::now();
    if req.files.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "ok": false, "error": "files array cannot be empty" })),
        );
    }

    let client = match client_for(&state, req.target_id.as_deref(), req.session.as_deref()).await {
        Ok(c) => c,
        Err(e) => return (StatusCode::BAD_REQUEST, Json(json!({ "ok": false, "error": e }))),
    };

    if let Err(e) = client.eval_js("window.__stationUploadFiles = []; true", 5000).await {
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "ok": false, "error": e })));
    }

    const CHUNK_SIZE: usize = 512 * 1024; // 512 KB binary -> ~683 KB base64 per CDP call
    for path_str in &req.files {
        let path = PathBuf::from(path_str);
        let meta = match std::fs::metadata(&path) {
            Ok(m) if m.is_file() => m,
            _ => {
                let _ = client.eval_js("window.__stationUploadFiles = null; true", 2000).await;
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({ "ok": false, "error": format!("File not found or not a regular file: {}", path_str) })),
                );
            }
        };
        if meta.len() > 200 * 1024 * 1024 {
            let _ = client.eval_js("window.__stationUploadFiles = null; true", 2000).await;
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "ok": false, "error": "File exceeds 200 MB safety cap" })),
            );
        }
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) => {
                let _ = client.eval_js("window.__stationUploadFiles = null; true", 2000).await;
                return (
                    StatusCode::BAD_REQUEST,
                    Json(json!({ "ok": false, "error": format!("Failed to read {}: {}", path_str, e) })),
                );
            }
        };

        let _ = client.eval_js("window.__stationUploadParts = []; true", 5000).await;
        for chunk in bytes.chunks(CHUNK_SIZE) {
            let b64 = base64::engine::general_purpose::STANDARD.encode(chunk);
            let b64_json = serde_json::to_string(&b64).unwrap_or_else(|_| "\"\"".into());
            let push_js = format!(
                "window.__stationUploadParts.push(Uint8Array.from(atob({}), c => c.charCodeAt(0))); true",
                b64_json
            );
            if let Err(e) = client.eval_js(&push_js, 15000).await {
                return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "ok": false, "error": e })));
            }
        }

        let filename = path.file_name().and_then(|n| n.to_str()).unwrap_or("upload.bin");
        let mime = dom::mime_for_filename(filename);
        let name_json = serde_json::to_string(filename).unwrap_or_else(|_| "\"upload.bin\"".into());
        let mime_json = serde_json::to_string(mime).unwrap_or_else(|_| "\"application/octet-stream\"".into());
        let finalize_js = format!(
            "window.__stationUploadFiles.push(new File(window.__stationUploadParts, {}, {{ type: {} }})); window.__stationUploadParts = null; true",
            name_json, mime_json
        );
        if let Err(e) = client.eval_js(&finalize_js, 10000).await {
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "ok": false, "error": e })));
        }
    }

    let attach_js = dom::build_upload_attach_js(req.selector.as_deref().unwrap_or("input[type=\"file\"]"));
    match client.eval_js(&attach_js, 10000).await {
        Ok(val) => {
            let ok = val.get("ok").and_then(|b| b.as_bool()).unwrap_or(false);
            let err = val.get("error").and_then(|s| s.as_str()).map(String::from);
            (
                StatusCode::OK,
                Json(json!({
                    "ok": ok,
                    "data": val,
                    "error": err,
                    "latency_ms": (start.elapsed().as_secs_f64() * 1000.0 * 100.0).round() / 100.0,
                })),
            )
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "ok": false, "error": e })),
        ),
    }
}

async fn new_tab_handler(
    State(state): State<AppState>,
    Json(payload): Json<NavigateRequest>,
) -> impl IntoResponse {
    if let Err(e) = check_url(&payload.url) {
        return (StatusCode::BAD_REQUEST, Json(json!({ "ok": false, "error": e })));
    }
    let bg = payload.background.unwrap_or(false);
    match state.browser_mgr.create_tab_opts(&payload.url, bg, Some(&state.cdp)).await {
        Ok(target) => (StatusCode::OK, Json(json!({ "ok": true, "tab": target }))),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "ok": false, "error": e }))),
    }
}

async fn activate_tab_handler(
    State(state): State<AppState>,
    Json(payload): Json<TabActionRequest>,
) -> impl IntoResponse {
    let _ = state.browser_mgr.activate_tab(&payload.target_id).await;
    (StatusCode::OK, Json(json!({ "ok": true })))
}

async fn close_tab_handler(
    State(state): State<AppState>,
    Json(payload): Json<TabActionRequest>,
) -> impl IntoResponse {
    state.tab_pool.remove(&payload.target_id).await;
    let _ = state.browser_mgr.close_tab(&payload.target_id).await;
    (StatusCode::OK, Json(json!({ "ok": true })))
}

async fn command_handler(
    State(state): State<AppState>,
    Json(payload): Json<CommandRequest>,
) -> impl IntoResponse {
    let start = Instant::now();
    let code = payload.code.unwrap_or_default();
    let timeout = payload.timeout.unwrap_or(30000);
    let action = payload.action.as_deref().unwrap_or("exec");

    let session = payload.session.as_deref();
    let target_id = payload.target_id.as_deref();
    let res = if action == "raw" {
        let method = payload.method.as_deref().unwrap_or("Runtime.evaluate");
        raw_target(
            &state,
            target_id,
            session,
            method,
            payload.params.unwrap_or_else(|| json!({})),
            timeout,
        )
        .await
    } else {
        eval_target(&state, target_id, session, &code, timeout).await
    };
    let elapsed = start.elapsed().as_secs_f64() * 1000.0;
    let latency_rounded = (elapsed * 100.0).round() / 100.0;

    match res {
        Ok(val) => {
            let snippet: String = code.chars().filter(|c| !c.is_control()).take(50).collect();
            println!(
                "  {} [{:>7}ms] JS Eval: {}...",
                "⚡".green(),
                format!("{:.2}", latency_rounded).cyan(),
                snippet.dimmed()
            );

            (
                StatusCode::OK,
                Json(CommandResponse {
                    ok: true,
                    data: Some(val),
                    error: None,
                    latency_ms: latency_rounded,
                }),
            )
        }
        Err(err) => {
            println!(
                "  {} [{:>7}ms] JS Error: {}",
                "✖".red(),
                format!("{:.2}", latency_rounded).yellow(),
                err.red()
            );

            (
                StatusCode::OK,
                Json(CommandResponse {
                    ok: false,
                    data: None,
                    error: Some(err),
                    latency_ms: latency_rounded,
                }),
            )
        }
    }
}

async fn inject_handler(
    State(state): State<AppState>,
    Json(payload): Json<InjectRequest>,
) -> impl IntoResponse {
    let start = Instant::now();
    let auto_send = payload.auto_send.unwrap_or(true);
    let res = gemini::inject_prompt(&state, payload.session.as_deref(), &payload.prompt, auto_send).await;
    let elapsed = start.elapsed().as_secs_f64() * 1000.0;
    let latency_rounded = (elapsed * 100.0).round() / 100.0;

    match res {
        Ok(data) => (
            StatusCode::OK,
            Json(json!({
                "ok": true,
                "data": data,
                "latency_ms": latency_rounded,
            })),
        ),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({
                "ok": false,
                "error": e,
                "latency_ms": latency_rounded,
            })),
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::is_main;

    #[test]
    fn is_main_matches_host_and_subdomains_only() {
        assert!(is_main("gemini.google.com", "gemini.google.com"));
        assert!(is_main("www.linkedin.com", "linkedin.com"));
        assert!(!is_main("www.linkedin.com", "instagram.com"));
        assert!(!is_main("notlinkedin.com", "linkedin.com"));
        assert!(!is_main("about:blank", "x.com"));
    }
}
