mod browser;
mod cdp;
mod dom;
mod gemini;
mod mcp;
mod server;

use std::path::PathBuf;
use std::sync::Arc;
use clap::{Parser, Subcommand};
use colored::Colorize;
use serde_json::{json, Value};
use tokio::net::TcpListener;

use crate::browser::BrowserManager;
use crate::cdp::{CdpClient, CdpTabPool};
use crate::server::{create_router, AppState};

#[derive(Subcommand, Debug, Clone)]
enum CliSubcommand {
    /// Start the Model Context Protocol (MCP) server over stdio (for Claude, Cursor, Windsurf, Antigravity)
    Mcp {
        /// Automatically start the Station daemon in the background if it is offline (default: true)
        #[arg(long, default_value_t = true)]
        auto_start: bool,

        /// Disable automatic daemon startup when offline
        #[arg(long)]
        no_auto_start: bool,

        /// Browser profile name when auto-starting
        #[arg(long)]
        profile_name: Option<String>,
    },
    /// Run health diagnostics on Chrome, CDP, auth token, tab pool, and MCP readiness
    Doctor {
        /// Output raw JSON instead of human-readable checklist
        #[arg(long)]
        json: bool,
    },
    /// Print the compact interactive @e1..@eN DOM snapshot of a tab
    Snapshot {
        /// Optional session alias or host (e.g. linkedin, github)
        #[arg(short, long)]
        session: Option<String>,
        /// Optional exact tab target_id
        #[arg(long)]
        target_id: Option<String>,
        /// Only include elements currently visible in the viewport
        #[arg(long)]
        viewport_only: bool,
    },
    /// Extract clean Markdown from an open tab or any URL (using your logged-in browser session)
    Read {
        /// Optional URL to open briefly in a background tab, extract Markdown, and close
        url: Option<String>,
        /// Optional session alias or host when reading an open tab
        #[arg(short, long)]
        session: Option<String>,
        /// Optional exact tab target_id
        #[arg(long)]
        target_id: Option<String>,
    },
    /// Interact with an element by @eN snapshot ref or CSS selector (click, fill, press, select, scroll)
    Act {
        /// Action: click | fill | press | select | hover | focus | scroll
        action: String,
        /// Target @eN ref (e.g. @e3) or CSS selector
        target: Option<String>,
        /// Value to fill/select, key to press, or scroll direction
        value: Option<String>,
        /// Optional session alias or host
        #[arg(short, long)]
        session: Option<String>,
        /// Optional exact tab target_id
        #[arg(long)]
        target_id: Option<String>,
    },
}

#[derive(Parser, Debug)]
#[command(name = "station")]
#[command(author = "Station Contributors")]
#[command(version)]
#[command(about = "Sub-ms Authenticated Browser Daemon & Native MCP Server in Rust", long_about = None)]
struct Args {
    #[command(subcommand)]
    command: Option<CliSubcommand>,

    /// Port for the HTTP daemon (19825 belongs to OpenCLI's own daemon, so don't use it)
    #[arg(short, long, default_value_t = 19826, global = true)]
    port: u16,

    /// Initial URL to load (e.g. https://claude.ai, https://x.com). Default: about:blank, or Gemini with --gemini
    #[arg(short, long)]
    url: Option<String>,

    /// Gemini preset: opens gemini.google.com with the saved Gemini profile (~/.flossi/gemini_profile)
    #[arg(long)]
    gemini: bool,

    /// Open standard browser window with multi-tabs & address bar instead of single app frame
    #[arg(long)]
    standard_window: bool,

    /// Profile name, stored in ~/.flossi/profiles/<name> (default: "default")
    #[arg(long)]
    profile_name: Option<String>,

    /// Chrome remote debugging CDP port
    #[arg(long, default_value_t = 9222)]
    cdp_port: u16,

    /// Custom persistent browser profile directory path
    #[arg(long)]
    profile_dir: Option<PathBuf>,

    /// Connect to existing Chrome without spawning a new window
    #[arg(long)]
    no_browser: bool,

    /// Check status of running daemon and exit
    #[arg(long)]
    status: bool,

    /// Run health diagnostics and exit
    #[arg(long)]
    doctor: bool,

    /// List all open tabs/pages in the browser and exit
    #[arg(long)]
    tabs: bool,

    /// Navigate active browser tab to a URL and exit
    #[arg(long)]
    navigate: Option<String>,

    /// Capture screenshot of active page to a file and exit
    #[arg(long)]
    screenshot: Option<PathBuf>,

    /// Evaluate JavaScript expression against active window and exit
    #[arg(long)]
    eval: Option<String>,

    /// Replace an older station already running on the port (never kills other programs)
    #[arg(short, long)]
    force: bool,
}

fn print_banner(port: u16, cdp_port: u16, url: &str, profile: &str) {
    println!();
    println!("{}", "  ╔══════════════════════════════════════════════════════════════╗".cyan());
    println!("{}", "  ║              STATION v0.4 · NATIVE CDP & MCP ENGINE          ║".cyan().bold());
    println!("{}", "  ║     Sub-ms Authenticated Browser Daemon · Zero Extensions    ║".cyan());
    println!("{}", "  ╚══════════════════════════════════════════════════════════════╝".cyan());
    println!();
    println!("  • HTTP RPC Daemon:  {}", format!("http://127.0.0.1:{}", port).green().bold());
    println!("  • MCP Stdio Server: {}", "station mcp --auto-start".cyan().bold());
    println!("  • Chrome CDP Port:  {}", format!("127.0.0.1:{}", cdp_port).yellow());
    println!("  • Active URL:       {}", url.bold());
    println!("  • Isolated Profile: {}", profile.magenta());
    println!();
}

async fn run_cli_doctor(client: &reqwest::Client, port: u16, token: &str, as_json: bool) -> Result<(), Box<dyn std::error::Error>> {
    let chrome_bin = BrowserManager::find_chrome_binary().ok().map(|p| p.display().to_string());
    let tok_path = server::token_path();
    let tok_ok = tok_path.exists();
    let exe_path = std::env::current_exe().ok().map(|p| p.display().to_string()).unwrap_or_else(|| "station".into());

    let daemon_url = format!("http://127.0.0.1:{}/doctor", port);
    let live = match client.get(&daemon_url).header(server::TOKEN_HEADER, token).timeout(std::time::Duration::from_secs(3)).send().await {
        Ok(r) if r.status().is_success() => r.json::<Value>().await.ok(),
        _ => None,
    };

    if as_json {
        if let Some(v) = live {
            println!("{}", serde_json::to_string_pretty(&v)?);
        } else {
            println!("{}", serde_json::to_string_pretty(&json!({
                "ok": false,
                "daemon_running": false,
                "http_port": port,
                "chrome_binary": chrome_bin,
                "token_file": tok_path.display().to_string(),
                "token_present": tok_ok,
                "mcp_command": format!("{} mcp --auto-start", exe_path),
            }))?);
        }
        return Ok(());
    }

    println!();
    println!("  {}", "Station Doctor".bold());
    println!("  {}", "──────────────".dimmed());
    match &chrome_bin {
        Some(bin) => println!("  {} Chrome binary:    {}", "✔".green(), bin),
        None => println!("  {} Chrome binary:    {}", "✖".red(), "Not found (install Google Chrome, Brave, or Chromium)".red()),
    }
    if tok_ok {
        println!("  {} Auth token:       {} (loaded)", "✔".green(), tok_path.display());
    } else {
        println!("  {} Auth token:       {} (missing)", "✖".red(), tok_path.display());
    }
    println!("  {} MCP server cmd:   {} mcp --auto-start", "✔".green(), exe_path);

    if let Some(v) = live {
        let lat = v.get("cdp").and_then(|c| c.get("eval_latency_ms")).and_then(|n| n.as_f64()).unwrap_or(0.0);
        let tabs = v.get("cdp").and_then(|c| c.get("open_page_tabs")).and_then(|n| n.as_u64()).unwrap_or(0);
        let pooled = v.get("cdp").and_then(|c| c.get("pooled_secondary_sockets")).and_then(|n| n.as_u64()).unwrap_or(0);
        let prod = v.get("browser").and_then(|b| b.get("product")).and_then(|s| s.as_str()).unwrap_or("Connected");
        println!("  {} Station daemon:   {} on 127.0.0.1:{}", "✔".green(), "ONLINE".green().bold(), port);
        println!("  {} Browser CDP:      {} · {:.2} ms eval · {} open tab(s) ({} pooled)", "✔".green(), prod, lat, tabs, pooled);
    } else {
        println!("  {} Station daemon:   {} on 127.0.0.1:{} (start with `station --standard-window`)", "ℹ".yellow(), "OFFLINE".yellow().bold(), port);
    }
    println!();
    Ok(())
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();

    // Subcommand: MCP stdio server (must never write banner/logs to stdout!)
    if let Some(CliSubcommand::Mcp { auto_start, no_auto_start, profile_name }) = args.command {
        return mcp::run_stdio_server(mcp::McpConfig {
            port: args.port,
            auto_start: auto_start && !no_auto_start,
            profile_name: profile_name.or(args.profile_name),
        })
        .await;
    }

    let client = reqwest::Client::builder().no_proxy().build().unwrap_or_default();
    let token = server::load_or_create_token()?;

    if args.doctor {
        return run_cli_doctor(&client, args.port, &token, false).await;
    }

    if let Some(sub) = args.command {
        match sub {
            CliSubcommand::Doctor { json: as_json } => {
                return run_cli_doctor(&client, args.port, &token, as_json).await;
            }
            CliSubcommand::Snapshot { session, target_id, viewport_only } => {
                let endpoint = format!("http://127.0.0.1:{}/snapshot", args.port);
                let resp: Value = client
                    .post(&endpoint)
                    .header(server::TOKEN_HEADER, &token)
                    .json(&json!({ "session": session, "target_id": target_id, "viewport_only": viewport_only }))
                    .send()
                    .await?
                    .json()
                    .await?;
                if let Some(txt) = resp.get("data").and_then(|d| d.get("snapshot_text")).and_then(|s| s.as_str()) {
                    println!("{}", txt);
                } else {
                    println!("{}", serde_json::to_string_pretty(&resp)?);
                }
                return Ok(());
            }
            CliSubcommand::Read { url, session, target_id } => {
                let endpoint = format!("http://127.0.0.1:{}/read", args.port);
                let resp: Value = client
                    .post(&endpoint)
                    .header(server::TOKEN_HEADER, &token)
                    .json(&json!({ "url": url, "session": session, "target_id": target_id }))
                    .send()
                    .await?
                    .json()
                    .await?;
                if let Some(md) = resp.get("data").and_then(|d| d.get("markdown")).and_then(|s| s.as_str()) {
                    println!("{}", md);
                } else {
                    println!("{}", serde_json::to_string_pretty(&resp)?);
                }
                return Ok(());
            }
            CliSubcommand::Act { action, target, value, session, target_id } => {
                let endpoint = format!("http://127.0.0.1:{}/act", args.port);
                let resp: Value = client
                    .post(&endpoint)
                    .header(server::TOKEN_HEADER, &token)
                    .json(&json!({
                        "action": action,
                        "target": target,
                        "value": value,
                        "session": session,
                        "target_id": target_id,
                    }))
                    .send()
                    .await?
                    .json()
                    .await?;
                println!("{}", serde_json::to_string_pretty(&resp)?);
                return Ok(());
            }
            CliSubcommand::Mcp { .. } => unreachable!(),
        }
    }

    // CLI Mode: --status
    if args.status {
        let url = format!("http://127.0.0.1:{}/status", args.port);
        match client.get(&url).header(server::TOKEN_HEADER, &token).send().await {
            Ok(resp) => {
                let text = resp.text().await.unwrap_or_default();
                println!("{}", "Station Daemon: ONLINE".green().bold());
                println!("Response: {}", text);
                return Ok(());
            }
            Err(e) => {
                eprintln!("{}", format!("Station Daemon: OFFLINE ({})", e).red().bold());
                std::process::exit(1);
            }
        }
    }

    // CLI Mode: --tabs
    if args.tabs {
        let url = format!("http://127.0.0.1:{}/tabs", args.port);
        match client.get(&url).header(server::TOKEN_HEADER, &token).send().await {
            Ok(resp) => {
                let json_resp: Value = resp.json().await?;
                println!("{}", serde_json::to_string_pretty(&json_resp)?);
                return Ok(());
            }
            Err(e) => {
                eprintln!("{}", format!("Failed to fetch tabs: {}", e).red());
                std::process::exit(1);
            }
        }
    }

    // CLI Mode: --navigate <URL>
    if let Some(nav_url) = args.navigate {
        let endpoint = format!("http://127.0.0.1:{}/navigate", args.port);
        let payload = json!({
            "url": nav_url,
            "new_tab": false,
        });
        match client.post(&endpoint).header(server::TOKEN_HEADER, &token).json(&payload).send().await {
            Ok(resp) => {
                let json_resp: Value = resp.json().await?;
                println!("{}", serde_json::to_string_pretty(&json_resp)?);
                return Ok(());
            }
            Err(e) => {
                eprintln!("{}", format!("Navigation failed: {}", e).red());
                std::process::exit(1);
            }
        }
    }

    // CLI Mode: --screenshot <FILE>
    if let Some(out_path) = args.screenshot {
        let endpoint = format!("http://127.0.0.1:{}/screenshot", args.port);
        match client.post(&endpoint).header(server::TOKEN_HEADER, &token).send().await {
            Ok(resp) => {
                let json_resp: Value = resp.json().await?;
                if let Some(b64) = json_resp.get("image_base64").and_then(|s| s.as_str()) {
                    use base64::Engine;
                    let bytes = base64::engine::general_purpose::STANDARD.decode(b64)?;
                    std::fs::write(&out_path, bytes)?;
                    println!("{} Screenshot saved to {}", "✔".green(), out_path.display());
                    return Ok(());
                } else {
                    eprintln!("{}", "No image data returned from screenshot endpoint".red());
                    std::process::exit(1);
                }
            }
            Err(e) => {
                eprintln!("{}", format!("Screenshot request failed: {}", e).red());
                std::process::exit(1);
            }
        }
    }

    // CLI Mode: --eval "<code>"
    if let Some(code) = args.eval {
        let url = format!("http://127.0.0.1:{}/command", args.port);
        let payload = json!({
            "action": "exec",
            "code": code,
        });

        match client.post(&url).header(server::TOKEN_HEADER, &token).json(&payload).send().await {
            Ok(resp) => {
                let json_resp: Value = resp.json().await?;
                println!("{}", serde_json::to_string_pretty(&json_resp)?);
                return Ok(());
            }
            Err(e) => {
                eprintln!("{}", format!("Failed to evaluate command: {}", e).red());
                std::process::exit(1);
            }
        }
    }

    // --gemini only fills in what the caller left out.
    let start_url = args.url.unwrap_or_else(|| if args.gemini { gemini::URL } else { "about:blank" }.to_string());
    let flossi = PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".to_string())).join(".flossi");
    let profile_dir = match (args.profile_dir, args.profile_name) {
        (Some(p), _) => p,
        (None, Some(name)) => flossi.join("profiles").join(name),
        (None, None) if args.gemini => flossi.join(gemini::LEGACY_PROFILE),
        (None, None) => flossi.join("profiles").join("default"),
    };

    let mut browser_mgr = BrowserManager::new(args.cdp_port, profile_dir, start_url.clone(), args.standard_window);

    let profile_display = browser_mgr.profile_dir.display().to_string();
    print_banner(args.port, args.cdp_port, &start_url, &profile_display);

    // 1. Launch or attach to Chrome
    if !args.no_browser {
        if let Err(e) = browser_mgr.ensure_browser_running().await {
            eprintln!("  {} {}", "✖ Browser Launch Error:".red().bold(), e);
            eprintln!("  {} Trying to proceed with existing CDP connection...", "ℹ".yellow());
        }
    }

    // 2. Discover page target
    println!("  \x1b[36mℹ\x1b[0m Resolving Target on CDP port {}...", args.cdp_port);
    let target = match browser_mgr.resolve_target(None, Some(&url_host(&start_url))).await {
        Ok(t) => t,
        Err(e) => {
            eprintln!("  {} {}", "✖ Target Error:".red(), e);
            eprintln!("  {} Please ensure Chrome is open with your website loaded.", "ℹ".yellow());
            return Ok(());
        }
    };

    println!("  {} Connected Target: {} ({})", "✔".green(), target.title.bold(), target.url.dimmed());

    let ws_url = target.websocket_debugger_url
        .ok_or_else(|| "Target does not have a webSocketDebuggerUrl".to_string())?;

    // 3. Connect CDP WebSocket client + Secondary Tab Pool
    println!("  \x1b[36mℹ\x1b[0m Connecting DevTools Protocol WebSocket: {}...", ws_url);
    let cdp = Arc::new(CdpClient::connect(args.cdp_port, ws_url, url_host(&start_url)).await?);
    let tab_pool = Arc::new(CdpTabPool::new());

    // 4. Initial status check (login state is only known on a Gemini tab)
    match server::page_status(&cdp).await {
        Ok(status) => match status.get("isLoggedIn").and_then(|v| v.as_bool()) {
            Some(true) => println!("  {} Gemini: {}", "✔".green(), "LOGGED IN".green().bold()),
            Some(false) => println!("  {} Gemini: {}", "ℹ".cyan(), "NOT LOGGED IN".cyan().bold()),
            None => {}
        },
        Err(e) => println!("  {} Tab check notice: {}", "ℹ".yellow(), e),
    }

    // 5. --force: replace an older station, but never another program
    let addr = format!("127.0.0.1:{}", args.port);
    if args.force {
        let ping = client.get(format!("http://{}/ping", addr)).send().await;
        let is_station = match ping {
            Ok(r) => r.json::<Value>().await.ok()
                .and_then(|v| v.get("daemon").and_then(|d| d.as_str()).map(|d| d == server::DAEMON_NAME || d == server::OLD_DAEMON_NAME))
                .unwrap_or(false),
            Err(_) => false,
        };
        if is_station {
            if let Ok(out) = std::process::Command::new("lsof").args(["-ti", &format!("tcp:{}", args.port), "-sTCP:LISTEN"]).output() {
                for pid in String::from_utf8_lossy(&out.stdout).lines().filter_map(|l| l.trim().parse::<i32>().ok()) {
                    println!("  {} Stopping previous station (PID {})...", "ℹ".yellow(), pid);
                    let _ = std::process::Command::new("kill").arg(pid.to_string()).status();
                }
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            }
        }
    }

    // 6. Start Axum HTTP Server
    let browser_mgr_arc = Arc::new(browser_mgr);
    let app_state = AppState {
        cdp: Arc::clone(&cdp),
        tab_pool,
        browser_mgr: Arc::clone(&browser_mgr_arc),
        port: args.port,
        token: Arc::new(token),
        main_host: url_host(&start_url).into(),
    };

    let router = create_router(app_state);
    let listener = match TcpListener::bind(&addr).await {
        Ok(l) => l,
        Err(e) => {
            eprintln!("  {} Failed to bind to {}: {}", "✖".red(), addr, e);
            eprintln!("  {} Another program holds the port. Use --port <PORT> (--force only replaces an older station).", "ℹ".yellow());
            return Err(e.into());
        }
    };

    println!();
    println!("  {} Station Ready! Listening on http://{}", "🚀".green(), addr.bold());
    println!("  {} Primitives: /snapshot · /act · /read · /upload · /screenshot · /command", "💡".cyan());
    println!();

    axum::serve(listener, router).await?;

    Ok(())
}

/// "https://www.linkedin.com/jobs" -> "www.linkedin.com"; used to pick the right tab.
fn url_host(url: &str) -> String {
    let rest = url.split("://").nth(1).unwrap_or(url);
    rest.split(['/', '?', '#']).next().unwrap_or(rest).to_string()
}
