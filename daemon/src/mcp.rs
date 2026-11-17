//! Native Model Context Protocol (MCP) Server over stdio (JSON-RPC 2.0).
//! Exposes Station's sub-ms authenticated browser primitives, resources, and workflow prompts
//! to Claude Code, Claude Desktop, Cursor, Windsurf, and Antigravity with zero Node/Python wrappers.

use std::io::{self, BufRead, Write};
use std::process::{Command, Stdio};
use std::time::Duration;
use base64::Engine;
use serde_json::{json, Value};

use crate::server;

const MCP_PROTOCOL_VERSION: &str = "2024-11-05";

pub struct McpConfig {
    pub port: u16,
    pub auto_start: bool,
    pub profile_name: Option<String>,
}

struct StationHttp {
    port: u16,
    auto_start: bool,
    profile_name: Option<String>,
    client: reqwest::Client,
}

impl StationHttp {
    fn new(cfg: McpConfig) -> Self {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(45))
            .no_proxy()
            .build()
            .unwrap_or_default();
        Self {
            port: cfg.port,
            auto_start: cfg.auto_start,
            profile_name: cfg.profile_name,
            client,
        }
    }

    fn base(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    fn token(&self) -> String {
        server::load_or_create_token().unwrap_or_default()
    }

    async fn is_online(&self) -> bool {
        let url = format!("{}/ping", self.base());
        match self.client.get(&url).timeout(Duration::from_millis(600)).send().await {
            Ok(r) => r.status().is_success(),
            Err(_) => false,
        }
    }

    /// Ensures the local `station` HTTP/CDP daemon is running; spawns it in background if `auto_start` is true.
    async fn ensure_daemon(&self) -> Result<(), String> {
        if self.is_online().await {
            return Ok(());
        }
        if !self.auto_start {
            return Err(format!(
                "Station daemon is offline on 127.0.0.1:{}. Start it with `station --standard-window` or launch MCP with `--auto-start`.",
                self.port
            ));
        }

        let exe = std::env::current_exe().map_err(|e| format!("Cannot resolve station binary path: {}", e))?;
        let mut cmd = Command::new(exe);
        cmd.arg("--port")
            .arg(self.port.to_string())
            .arg("--standard-window");
        if let Some(ref prof) = self.profile_name {
            cmd.arg("--profile-name").arg(prof);
        }
        cmd.stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());

        cmd.spawn()
            .map_err(|e| format!("Failed to auto-start station daemon: {}", e))?;

        for _ in 0..40 {
            tokio::time::sleep(Duration::from_millis(250)).await;
            if self.is_online().await {
                return Ok(());
            }
        }
        Err("Timed out waiting 10s for auto-started station daemon to come online.".to_string())
    }

    async fn get_json(&self, path: &str) -> Result<Value, String> {
        self.ensure_daemon().await?;
        let resp = self
            .client
            .get(format!("{}{}", self.base(), path))
            .header(server::TOKEN_HEADER, self.token())
            .send()
            .await
            .map_err(|e| format!("HTTP GET {} failed: {}", path, e))?;
        resp.json::<Value>().await.map_err(|e| format!("Invalid JSON from {}: {}", path, e))
    }

    async fn post_json(&self, path: &str, body: Value) -> Result<Value, String> {
        self.ensure_daemon().await?;
        let resp = self
            .client
            .post(format!("{}{}", self.base(), path))
            .header(server::TOKEN_HEADER, self.token())
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("HTTP POST {} failed: {}", path, e))?;
        resp.json::<Value>().await.map_err(|e| format!("Invalid JSON from {}: {}", path, e))
    }
}

pub async fn run_stdio_server(cfg: McpConfig) -> Result<(), Box<dyn std::error::Error>> {
    let bridge = StationHttp::new(cfg);
    let stdin = io::stdin();
    let mut reader = stdin.lock();
    let mut stdout = io::stdout();

    loop {
        let Some((msg, content_length_framed)) = read_rpc_message(&mut reader)? else {
            break;
        };

        // Notifications have no "id" — acknowledge silently without sending a response frame.
        let Some(id) = msg.get("id").cloned() else {
            continue;
        };

        let method = msg.get("method").and_then(|m| m.as_str()).unwrap_or("");
        let params = msg.get("params").cloned().unwrap_or_else(|| json!({}));

        let reply = match method {
            "initialize" => {
                let client_proto = params
                    .get("protocolVersion")
                    .and_then(|v| v.as_str())
                    .unwrap_or(MCP_PROTOCOL_VERSION);
                let negotiated = if client_proto.starts_with("2025-") || client_proto.starts_with("2024-") {
                    client_proto
                } else {
                    MCP_PROTOCOL_VERSION
                };
                rpc_ok(
                    id,
                    json!({
                        "protocolVersion": negotiated,
                        "capabilities": {
                            "tools": { "listChanged": false },
                            "resources": { "subscribe": false, "listChanged": false },
                            "prompts": { "listChanged": false }
                        },
                        "serverInfo": {
                            "name": "station",
                            "version": env!("CARGO_PKG_VERSION")
                        },
                        "instructions": "Station drives a real authenticated local Chrome browser at sub-millisecond CDP speed (zero extensions). Workflow: 1) Call `station_tabs` or `station_navigate` to open/pick a page (use `background: true` to avoid stealing focus). 2) Call `station_read` for clean Markdown text or `station_snapshot` to get numbered `@e1..@eN` interactive element refs. 3) Call `station_act` (`click`, `fill`, `select`, `press`, `scroll`) using `@eN` refs. Never bypass CAPTCHAs or submit irreversible payments/applications without asking the user first."
                    }),
                )
            }
            "ping" => rpc_ok(id, json!({})),
            "tools/list" => rpc_ok(id, json!({ "tools": tool_definitions() })),
            "tools/call" => {
                let name = params.get("name").and_then(|n| n.as_str()).unwrap_or("");
                let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
                let result = dispatch_tool(&bridge, name, args).await;
                rpc_ok(id, result)
            }
            "resources/list" => rpc_ok(id, json!({ "resources": resource_definitions() })),
            "resources/read" => {
                let uri = params.get("uri").and_then(|u| u.as_str()).unwrap_or("");
                match read_resource(&bridge, uri).await {
                    Ok(contents) => rpc_ok(id, json!({ "contents": [contents] })),
                    Err(e) => rpc_err(id, -32602, &e),
                }
            }
            "prompts/list" => rpc_ok(id, json!({ "prompts": prompt_definitions() })),
            "prompts/get" => {
                let name = params.get("name").and_then(|n| n.as_str()).unwrap_or("");
                let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
                match get_prompt(name, &args) {
                    Ok(val) => rpc_ok(id, val),
                    Err(e) => rpc_err(id, -32602, &e),
                }
            }
            _ => rpc_err(id, -32601, &format!("Method not found: {}", method)),
        };

        write_rpc_message(&mut stdout, &reply, content_length_framed)?;
    }

    Ok(())
}

/// Supports both standard MCP newline-delimited JSON and LSP-style `Content-Length:` framing.
fn read_rpc_message<R: BufRead>(reader: &mut R) -> io::Result<Option<(Value, bool)>> {
    let mut line = String::new();
    loop {
        line.clear();
        let n = reader.read_line(&mut line)?;
        if n == 0 {
            return Ok(None);
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("Content-Length:") {
            let len: usize = rest
                .trim()
                .parse()
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            // Consume remaining header lines until blank line
            loop {
                let mut hdr = String::new();
                if reader.read_line(&mut hdr)? == 0 || hdr.trim().is_empty() {
                    break;
                }
            }
            let mut buf = vec![0u8; len];
            reader.read_exact(&mut buf)?;
            let val: Value = serde_json::from_slice(&buf)
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            return Ok(Some((val, true)));
        }
        let val: Value = serde_json::from_str(trimmed)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        return Ok(Some((val, false)));
    }
}

fn write_rpc_message<W: Write>(writer: &mut W, msg: &Value, framed: bool) -> io::Result<()> {
    let body = serde_json::to_string(msg)?;
    if framed {
        write!(writer, "Content-Length: {}\r\n\r\n{}", body.len(), body)?;
    } else {
        writeln!(writer, "{}", body)?;
    }
    writer.flush()
}

fn rpc_ok(id: Value, result: Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result
    })
}

fn rpc_err(id: Value, code: i64, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {
            "code": code,
            "message": message
        }
    })
}

fn tool_text(text: String, is_error: bool) -> Value {
    json!({
        "content": [{ "type": "text", "text": text }],
        "isError": is_error
    })
}

async fn dispatch_tool(bridge: &StationHttp, name: &str, args: Value) -> Value {
    match name {
        "station_status" => {
            let mut qs = Vec::new();
            if let Some(s) = args.get("session").and_then(|v| v.as_str()) {
                qs.push(format!("session={}", urlencoding_simple(s)));
            }
            if let Some(t) = args.get("target_id").and_then(|v| v.as_str()) {
                qs.push(format!("target_id={}", urlencoding_simple(t)));
            }
            let path = if qs.is_empty() {
                "/status".to_string()
            } else {
                format!("/status?{}", qs.join("&"))
            };
            match bridge.get_json(&path).await {
                Ok(v) => tool_text(serde_json::to_string_pretty(&v).unwrap_or_default(), !is_ok(&v)),
                Err(e) => tool_text(e, true),
            }
        }
        "station_doctor" => match bridge.get_json("/doctor").await {
            Ok(v) => tool_text(serde_json::to_string_pretty(&v).unwrap_or_default(), false),
            Err(e) => tool_text(e, true),
        },
        "station_tabs" => {
            let action = args.get("action").and_then(|v| v.as_str()).unwrap_or("list");
            let res = match action {
                "list" => bridge.get_json("/tabs").await,
                "open" => {
                    let Some(url) = args.get("url").and_then(|v| v.as_str()) else {
                        return tool_text("Missing `url` for action='open'".into(), true);
                    };
                    let background = args.get("background").and_then(|v| v.as_bool()).unwrap_or(true);
                    bridge.post_json("/tabs/new", json!({ "url": url, "background": background })).await
                }
                "activate" => {
                    let Some(tid) = args.get("target_id").and_then(|v| v.as_str()) else {
                        return tool_text("Missing `target_id` for action='activate'".into(), true);
                    };
                    bridge.post_json("/tabs/activate", json!({ "target_id": tid })).await
                }
                "close" => {
                    let Some(tid) = args.get("target_id").and_then(|v| v.as_str()) else {
                        return tool_text("Missing `target_id` for action='close'".into(), true);
                    };
                    bridge.post_json("/tabs/close", json!({ "target_id": tid })).await
                }
                other => Err(format!("Unknown action '{}'. Expected list, open, activate, or close.", other)),
            };
            match res {
                Ok(v) => tool_text(serde_json::to_string_pretty(&v).unwrap_or_default(), !is_ok(&v)),
                Err(e) => tool_text(e, true),
            }
        }
        "station_navigate" => match bridge.post_json("/navigate", args).await {
            Ok(v) => tool_text(serde_json::to_string_pretty(&v).unwrap_or_default(), !is_ok(&v)),
            Err(e) => tool_text(e, true),
        },
        "station_snapshot" => match bridge.post_json("/snapshot", args).await {
            Ok(v) => {
                if !is_ok(&v) {
                    return tool_text(serde_json::to_string_pretty(&v).unwrap_or_default(), true);
                }
                // Return the compact `@e1..@eN` text map directly so the LLM uses minimal context tokens!
                if let Some(txt) = v.get("data").and_then(|d| d.get("snapshot_text")).and_then(|s| s.as_str()) {
                    tool_text(txt.to_string(), false)
                } else {
                    tool_text(serde_json::to_string_pretty(&v).unwrap_or_default(), false)
                }
            }
            Err(e) => tool_text(e, true),
        },
        "station_act" => match bridge.post_json("/act", args).await {
            Ok(v) => tool_text(serde_json::to_string_pretty(&v).unwrap_or_default(), !is_ok(&v)),
            Err(e) => tool_text(e, true),
        },
        "station_read" => match bridge.post_json("/read", args).await {
            Ok(v) => {
                if !is_ok(&v) {
                    return tool_text(serde_json::to_string_pretty(&v).unwrap_or_default(), true);
                }
                if let Some(d) = v.get("data") {
                    let title = d.get("title").and_then(|s| s.as_str()).unwrap_or("");
                    let url = d.get("url").and_then(|s| s.as_str()).unwrap_or("");
                    let savings = d.get("token_savings_pct").and_then(|n| n.as_f64()).unwrap_or(0.0);
                    let md = d.get("markdown").and_then(|s| s.as_str()).unwrap_or("");
                    let formatted = format!(
                        "# {}\nSource: {}\nToken Reduction: {:.1}%\n\n---\n\n{}",
                        title, url, savings, md
                    );
                    tool_text(formatted, false)
                } else {
                    tool_text(serde_json::to_string_pretty(&v).unwrap_or_default(), false)
                }
            }
            Err(e) => tool_text(e, true),
        },
        "station_upload" => match bridge.post_json("/upload", args).await {
            Ok(v) => tool_text(serde_json::to_string_pretty(&v).unwrap_or_default(), !is_ok(&v)),
            Err(e) => tool_text(e, true),
        },
        "station_eval" => {
            let payload = json!({
                "action": "exec",
                "code": args.get("code").and_then(|c| c.as_str()).unwrap_or(""),
                "session": args.get("session"),
                "target_id": args.get("target_id"),
                "timeout": args.get("timeout").and_then(|t| t.as_u64()).unwrap_or(30000),
            });
            match bridge.post_json("/command", payload).await {
                Ok(v) => tool_text(serde_json::to_string_pretty(&v).unwrap_or_default(), !is_ok(&v)),
                Err(e) => tool_text(e, true),
            }
        }
        "station_screenshot" => {
            let save_path = args.get("save_path").and_then(|s| s.as_str()).map(String::from);
            match bridge.post_json("/screenshot", args).await {
                Ok(v) => {
                    if !is_ok(&v) {
                        return tool_text(serde_json::to_string_pretty(&v).unwrap_or_default(), true);
                    }
                    let b64 = v.get("image_base64").and_then(|s| s.as_str()).unwrap_or("");
                    let fmt = v.get("format").and_then(|s| s.as_str()).unwrap_or("png");
                    let mime = match fmt {
                        "jpeg" => "image/jpeg",
                        "webp" => "image/webp",
                        _ => "image/png",
                    };
                    let mut note = format!("Captured {} screenshot ({:.1} KB).", fmt.to_uppercase(), (b64.len() as f64 * 0.75) / 1024.0);
                    if let Some(path) = save_path {
                        if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(b64) {
                            if let Err(e) = std::fs::write(&path, bytes) {
                                note.push_str(&format!(" Failed to save to {}: {}", path, e));
                            } else {
                                note.push_str(&format!(" Saved to {}.", path));
                            }
                        }
                    }
                    json!({
                        "content": [
                            { "type": "text", "text": note },
                            { "type": "image", "data": b64, "mimeType": mime }
                        ],
                        "isError": false
                    })
                }
                Err(e) => tool_text(e, true),
            }
        }
        "station_inject" => match bridge.post_json("/inject", args).await {
            Ok(v) => tool_text(serde_json::to_string_pretty(&v).unwrap_or_default(), !is_ok(&v)),
            Err(e) => tool_text(e, true),
        },
        other => tool_text(format!("Unknown tool '{}'", other), true),
    }
}

fn is_ok(v: &Value) -> bool {
    v.get("ok").and_then(|b| b.as_bool()).unwrap_or(false)
}

fn urlencoding_simple(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (b as char).to_string(),
            _ => format!("%{:02X}", b),
        })
        .collect()
}

fn tool_definitions() -> Value {
    json!([
        {
            "name": "station_snapshot",
            "description": "Inspect interactive elements on a browser tab as numbered refs (@e1, @e2, ...) with page title, URL, headings, and scroll position. Prefer this over raw HTML before clicking or filling forms.",
            "annotations": { "title": "DOM Interactive Snapshot", "readOnlyHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "viewport_only": { "type": "boolean", "description": "Only return elements currently visible in the viewport (default: false)." },
                    "max_elements": { "type": "integer", "description": "Maximum interactive elements to index (default: 120, max: 500)." },
                    "session": { "type": "string", "description": "Optional site alias or host substring (e.g. 'linkedin', 'github', 'avito'). Omit for main tab." },
                    "target_id": { "type": "string", "description": "Exact tab target_id from station_tabs when multiple tabs share a domain." }
                }
            }
        },
        {
            "name": "station_act",
            "description": "Click, fill, select, press keys, hover, or scroll on a page using a @eN ref from station_snapshot or a CSS selector. Works cleanly with React, Vue, and Angular controlled inputs.",
            "annotations": { "title": "Interact With Element", "readOnlyHint": false, "openWorldHint": true },
            "inputSchema": {
                "type": "object",
                "required": ["action"],
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["click", "fill", "press", "select", "hover", "focus", "scroll"],
                        "description": "Interaction type."
                    },
                    "target": { "type": "string", "description": "Snapshot ref (e.g. '@e4') or CSS selector (e.g. 'input[name=q]'). Optional for page-level 'scroll'." },
                    "value": { "type": "string", "description": "Text for 'fill', option label/value for 'select', key name for 'press' ('Enter', 'Escape'), or direction for 'scroll' ('down', 'up', 'top', 'bottom')." },
                    "session": { "type": "string", "description": "Optional site alias or host substring." },
                    "target_id": { "type": "string", "description": "Exact tab target_id." }
                }
            }
        },
        {
            "name": "station_read",
            "description": "Extract clean, readable Markdown from an open authenticated tab—or pass `url` to read any web page in an ephemeral background tab using the user's logged-in session (zero API fees, ~90% fewer tokens than HTML).",
            "annotations": { "title": "Read Clean Markdown", "readOnlyHint": true, "openWorldHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "url": { "type": "string", "description": "Optional http(s) URL to open briefly in a background tab, extract Markdown, and auto-close." },
                    "max_chars": { "type": "integer", "description": "Max Markdown characters to return (default: 40000)." },
                    "wait_ms": { "type": "integer", "description": "Max milliseconds to wait for SPA hydration when `url` is provided (default: 2200)." },
                    "session": { "type": "string", "description": "Optional open tab session alias/host when `url` is omitted." },
                    "target_id": { "type": "string", "description": "Optional exact tab target_id when `url` is omitted." }
                }
            }
        },
        {
            "name": "station_tabs",
            "description": "List open browser tabs, open a new tab (defaults to background so user focus isn't interrupted), bring a tab to focus, or close a tab.",
            "annotations": { "title": "Manage Browser Tabs", "readOnlyHint": false },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "action": { "type": "string", "enum": ["list", "open", "activate", "close"], "description": "Tab operation (default: 'list')." },
                    "url": { "type": "string", "description": "URL required when action='open'." },
                    "background": { "type": "boolean", "description": "Open new tab in the background without stealing window focus (default: true)." },
                    "target_id": { "type": "string", "description": "Tab id required when action='activate' or 'close'." }
                }
            }
        },
        {
            "name": "station_navigate",
            "description": "Navigate the active tab (or a specific `session`/`target_id`) to an http(s) URL, or open it in a new tab.",
            "annotations": { "title": "Navigate URL", "readOnlyHint": false, "openWorldHint": true },
            "inputSchema": {
                "type": "object",
                "required": ["url"],
                "properties": {
                    "url": { "type": "string", "description": "Destination http:// or https:// URL." },
                    "new_tab": { "type": "boolean", "description": "Open in a new tab instead of navigating existing tab (default: false)." },
                    "background": { "type": "boolean", "description": "When new_tab=true, keep tab in background (default: false)." },
                    "session": { "type": "string", "description": "Optional session alias/host." },
                    "target_id": { "type": "string", "description": "Optional exact tab target_id." }
                }
            }
        },
        {
            "name": "station_upload",
            "description": "Attach one or more local files (e.g. PDF resume, cover letter, image, CSV) to an `<input type=\"file\">` element by @eN ref or CSS selector—bypasses Chrome file-chooser user-gesture blocks.",
            "annotations": { "title": "Upload Local Files", "readOnlyHint": false, "openWorldHint": true },
            "inputSchema": {
                "type": "object",
                "required": ["files"],
                "properties": {
                    "files": { "type": "array", "items": { "type": "string" }, "description": "Absolute local file paths to attach." },
                    "selector": { "type": "string", "description": "Snapshot ref (e.g. '@e9') or CSS selector (default: 'input[type=\"file\"]')." },
                    "session": { "type": "string" },
                    "target_id": { "type": "string" }
                }
            }
        },
        {
            "name": "station_eval",
            "description": "Evaluate arbitrary JavaScript (`awaitPromise: true`) inside any tab at sub-millisecond CDP speed and return the JSON-serialized result.",
            "annotations": { "title": "Evaluate JavaScript", "readOnlyHint": false, "openWorldHint": true },
            "inputSchema": {
                "type": "object",
                "required": ["code"],
                "properties": {
                    "code": { "type": "string", "description": "JavaScript expression or async IIFE to evaluate." },
                    "session": { "type": "string", "description": "Optional session alias/host." },
                    "target_id": { "type": "string", "description": "Optional exact tab target_id." },
                    "timeout": { "type": "integer", "description": "Timeout in milliseconds (default: 30000)." }
                }
            }
        },
        {
            "name": "station_screenshot",
            "description": "Capture a visual PNG or JPEG screenshot of a browser tab (returns native MCP image content + optional disk save).",
            "annotations": { "title": "Capture Screenshot", "readOnlyHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "format": { "type": "string", "enum": ["png", "jpeg", "webp"], "description": "Image format (default: 'png')." },
                    "full_page": { "type": "boolean", "description": "Capture full scrollable page height (default: false)." },
                    "save_path": { "type": "string", "description": "Optional local path to also write the image file." },
                    "session": { "type": "string" },
                    "target_id": { "type": "string" }
                }
            }
        },
        {
            "name": "station_inject",
            "description": "Inject a prompt into a rich web chat editor (Gemini, Claude, ChatGPT, ProseMirror) safely under TrustedHTML CSP and optionally press Send.",
            "annotations": { "title": "Inject Chat Prompt", "readOnlyHint": false, "openWorldHint": true },
            "inputSchema": {
                "type": "object",
                "required": ["prompt"],
                "properties": {
                    "prompt": { "type": "string", "description": "Text prompt to inject." },
                    "auto_send": { "type": "boolean", "description": "Click send / press Enter automatically (default: true)." },
                    "session": { "type": "string", "description": "Chat tab session (e.g. 'gemini', 'claude', 'chatgpt')." }
                }
            }
        },
        {
            "name": "station_status",
            "description": "Check Station daemon status, latency, and active page title/URL.",
            "annotations": { "title": "Tab & Daemon Status", "readOnlyHint": true },
            "inputSchema": {
                "type": "object",
                "properties": {
                    "session": { "type": "string" },
                    "target_id": { "type": "string" }
                }
            }
        },
        {
            "name": "station_doctor",
            "description": "Run end-to-end health diagnostics on the Station daemon, Chrome CDP socket, secondary tab connection pool, profile directory, and auth token.",
            "annotations": { "title": "Run Diagnostics", "readOnlyHint": true },
            "inputSchema": { "type": "object", "properties": {} }
        }
    ])
}

fn resource_definitions() -> Value {
    json!([
        {
            "uri": "station://doctor",
            "name": "Station Health & Capabilities",
            "description": "Live JSON diagnostics for Station daemon, Chrome CDP, tab pool, and auth token.",
            "mimeType": "application/json"
        },
        {
            "uri": "station://tabs",
            "name": "Open Browser Tabs",
            "description": "All currently open tabs in Station's Chrome instance.",
            "mimeType": "application/json"
        },
        {
            "uri": "station://active/markdown",
            "name": "Main Tab Clean Markdown",
            "description": "Clean Markdown content extracted from the currently active main tab.",
            "mimeType": "text/markdown"
        },
        {
            "uri": "station://active/snapshot",
            "name": "Main Tab Interactive Snapshot",
            "description": "Compact @e1..@eN interactive element tree of the active main tab.",
            "mimeType": "text/plain"
        }
    ])
}

async fn read_resource(bridge: &StationHttp, uri: &str) -> Result<Value, String> {
    match uri {
        "station://doctor" => {
            let v = bridge.get_json("/doctor").await?;
            Ok(json!({
                "uri": uri,
                "mimeType": "application/json",
                "text": serde_json::to_string_pretty(&v).unwrap_or_default()
            }))
        }
        "station://tabs" => {
            let v = bridge.get_json("/tabs").await?;
            Ok(json!({
                "uri": uri,
                "mimeType": "application/json",
                "text": serde_json::to_string_pretty(&v).unwrap_or_default()
            }))
        }
        "station://active/markdown" => {
            let v = bridge.post_json("/read", json!({})).await?;
            let md = v.get("data").and_then(|d| d.get("markdown")).and_then(|s| s.as_str()).unwrap_or("");
            Ok(json!({
                "uri": uri,
                "mimeType": "text/markdown",
                "text": md
            }))
        }
        "station://active/snapshot" => {
            let v = bridge.post_json("/snapshot", json!({})).await?;
            let snap = v.get("data").and_then(|d| d.get("snapshot_text")).and_then(|s| s.as_str()).unwrap_or("");
            Ok(json!({
                "uri": uri,
                "mimeType": "text/plain",
                "text": snap
            }))
        }
        other => Err(format!("Unknown resource URI: {}", other)),
    }
}

fn prompt_definitions() -> Value {
    json!([
        {
            "name": "job_hunt_scan",
            "description": "Scan authenticated job boards (LinkedIn, Welcome to the Jungle, Indeed, Wellfound) in background tabs, score roles against criteria, and summarize top matches.",
            "arguments": [
                { "name": "role", "description": "Target job title or stack (e.g. 'Senior Rust / Systems Engineer')", "required": true },
                { "name": "location", "description": "Preferred location or 'Remote'", "required": false }
            ]
        },
        {
            "name": "rent_listing_scan",
            "description": "Scan rental portals or logged-in housing groups, extract price/area/phone, filter out noisy posts, and rank top apartments/rooms.",
            "arguments": [
                { "name": "city_and_areas", "description": "Target city and neighborhoods", "required": true },
                { "name": "max_budget", "description": "Maximum monthly rent", "required": true }
            ]
        },
        {
            "name": "authenticated_assist",
            "description": "Navigate and pre-fill forms on an authenticated site using @eN snapshots and native file uploads while pausing before final submission.",
            "arguments": [
                { "name": "url", "description": "Target page URL", "required": true },
                { "name": "goal", "description": "What to extract or pre-fill", "required": true }
            ]
        }
    ])
}

fn get_prompt(name: &str, args: &Value) -> Result<Value, String> {
    let text = match name {
        "job_hunt_scan" => {
            let role = args.get("role").and_then(|s| s.as_str()).unwrap_or("Software Engineer");
            let loc = args.get("location").and_then(|s| s.as_str()).unwrap_or("Remote");
            format!(
                "Use Station MCP tools to run an authenticated job search for **{}** ({}).\n\
                1. Call `station_tabs` (`action: \"list\"`) to see if LinkedIn / job boards are already open.\n\
                2. Open search pages in background tabs (`background: true`) so you don't interrupt the user's focus.\n\
                3. Use `station_snapshot` and `station_read` to extract recent listings, company names, remote/hybrid tags, salary clues, and direct URLs.\n\
                4. Score each role 0–100 on fit and return a ranked Markdown table. Do not auto-submit applications without explicit user confirmation.",
                role, loc
            )
        }
        "rent_listing_scan" => {
            let areas = args.get("city_and_areas").and_then(|s| s.as_str()).unwrap_or("target neighborhoods");
            let budget = args.get("max_budget").and_then(|s| s.as_str()).unwrap_or("budget");
            format!(
                "Use Station MCP tools to scan rental listings in **{}** under **{}**.\n\
                1. Check open tabs with `station_tabs` or read target search URLs via `station_read`.\n\
                2. Extract price, neighborhood, room count/area, seller type (private vs agency), and phone/contact links.\n\
                3. Deduplicate cross-posted apartments and flag suspicious or 'wanted/looking-for' posts.\n\
                4. Present top matches sorted by neighborhood fit and value.",
                areas, budget
            )
        }
        "authenticated_assist" => {
            let url = args.get("url").and_then(|s| s.as_str()).unwrap_or("https://example.com");
            let goal = args.get("goal").and_then(|s| s.as_str()).unwrap_or("complete the workflow");
            format!(
                "Open `{}` using `station_tabs` (`action: \"open\"`, `background: false`) and accomplish: **{}**.\n\
                - Use `station_snapshot` to inspect `@eN` refs and `station_act` / `station_upload` to fill fields.\n\
                - If a login prompt or CAPTCHA appears, stop immediately and ask the user to complete it in the browser.\n\
                - Stop before clicking any final irreversible Submit / Pay button, capture `station_screenshot`, and ask the user to confirm.",
                url, goal
            )
        }
        other => return Err(format!("Unknown prompt '{}'", other)),
    };

    Ok(json!({
        "description": format!("Station workflow: {}", name),
        "messages": [
            {
                "role": "user",
                "content": { "type": "text", "text": text }
            }
        ]
    }))
}
