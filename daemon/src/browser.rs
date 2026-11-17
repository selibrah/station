use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::cdp::CdpClient;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChromeTarget {
    pub id: String,
    pub title: String,
    #[serde(rename = "type")]
    pub target_type: String,
    pub url: String,
    #[serde(rename = "webSocketDebuggerUrl")]
    pub websocket_debugger_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[allow(dead_code)]
pub struct ChromeVersion {
    #[serde(rename = "Browser")]
    pub browser: String,
    #[serde(rename = "Protocol-Version")]
    pub protocol_version: String,
    #[serde(rename = "webSocketDebuggerUrl")]
    pub web_socket_debugger_url: Option<String>,
}

pub struct BrowserManager {
    pub cdp_port: u16,
    pub profile_dir: PathBuf,
    pub initial_url: String,
    pub standard_window: bool,
    pub child_process: Option<Child>,
}

impl BrowserManager {
    pub fn new(cdp_port: u16, profile_dir: PathBuf, initial_url: String, standard_window: bool) -> Self {
        Self { cdp_port, profile_dir, initial_url, standard_window, child_process: None }
    }

    /// Check if Chrome with CDP is already active on cdp_port.
    pub async fn is_running(&self) -> bool {
        self.version_info().await.is_ok()
    }

    /// Returns Chrome version metadata from `/json/version`.
    pub async fn version_info(&self) -> Result<ChromeVersion, String> {
        let url = format!("http://127.0.0.1:{}/json/version", self.cdp_port);
        let client = reqwest::Client::builder()
            .timeout(Duration::from_millis(500))
            .build()
            .unwrap_or_default();

        let resp = client.get(&url).send().await.map_err(|e| e.to_string())?;
        resp.json::<ChromeVersion>().await.map_err(|e| e.to_string())
    }

    /// Locate Google Chrome on macOS or Linux
    pub fn find_chrome_binary() -> Result<PathBuf, String> {
        let candidate_paths = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            "/Applications/Arc.app/Contents/MacOS/Arc",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
        ];

        for path_str in candidate_paths {
            let path = Path::new(path_str);
            if path.exists() {
                return Ok(path.to_path_buf());
            }
        }

        Err("No supported Chrome/Chromium browser found. Please install Google Chrome.".to_string())
    }

    /// Spawns Chrome in dedicated minimalist App mode (or standard window) with isolated profile
    pub async fn ensure_browser_running(&mut self) -> Result<(), String> {
        if self.is_running().await {
            println!("  \x1b[32m✔\x1b[0m Attached to existing Chrome instance on CDP port {}", self.cdp_port);
            return Ok(());
        }

        let chrome_bin = Self::find_chrome_binary()?;
        std::fs::create_dir_all(&self.profile_dir)
            .map_err(|e| format!("Failed to create profile dir: {}", e))?;

        let mode_desc = if self.standard_window { "Standard Window (Multi-tab)" } else { "Minimalist App Frame" };
        println!("  \x1b[36mℹ\x1b[0m Spawning Universal Browser ({}) -> {}", mode_desc, self.initial_url);
        println!("  \x1b[36mℹ\x1b[0m Isolated Profile: {}", self.profile_dir.display());

        let mut cmd = Command::new(&chrome_bin);
        if self.standard_window {
            cmd.arg(&self.initial_url);
        } else {
            cmd.arg(format!("--app={}", self.initial_url));
        }

        let child = cmd
            .arg(format!("--user-data-dir={}", self.profile_dir.display()))
            .arg(format!("--remote-debugging-port={}", self.cdp_port))
            .arg("--remote-allow-origins=http://127.0.0.1")
            .arg("--no-first-run")
            .arg("--no-default-browser-check")
            .arg("--disable-features=Translate")
            .arg("--window-size=1280,920")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("Failed to launch Chrome: {}", e))?;

        self.child_process = Some(child);

        // Wait for CDP endpoint to become ready
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_secs(10) {
            if self.is_running().await {
                println!("  \x1b[32m✔\x1b[0m Browser started & CDP online!");
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(150)).await;
        }

        Err("Timed out waiting for Chrome CDP port to become active.".to_string())
    }

    /// Fetches all active page targets
    pub async fn get_all_targets(&self) -> Result<Vec<ChromeTarget>, String> {
        let url = format!("http://127.0.0.1:{}/json/list", self.cdp_port);
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(2))
            .build()
            .unwrap_or_default();

        let resp = client.get(&url).send().await
            .map_err(|e| format!("Failed to query targets from CDP: {}", e))?;

        let targets: Vec<ChromeTarget> = resp.json().await
            .map_err(|e| format!("Failed to parse targets: {}", e))?;

        Ok(targets.into_iter().filter(|t| t.target_type == "page").collect())
    }

    /// Resolves target dynamically by session name or URL pattern (used at daemon startup)
    pub async fn resolve_target(
        &self,
        session: Option<&str>,
        url_pattern: Option<&str>,
    ) -> Result<ChromeTarget, String> {
        let targets = self.get_all_targets().await?;

        if let Some(pat) = url_pattern {
            if !pat.is_empty() && pat != "about:blank" {
                for target in &targets {
                    if target.url.contains(pat) && target.websocket_debugger_url.is_some() {
                        return Ok(target.clone());
                    }
                }
            }
        }

        if let Some(s) = session {
            let pat = session_pattern(s);
            for target in &targets {
                if target.url.contains(&pat) && target.websocket_debugger_url.is_some() {
                    return Ok(target.clone());
                }
            }
        }

        for target in &targets {
            if (target.url.contains("accounts.google.com") || target.url.contains("login") || target.url.contains("auth"))
                && target.websocket_debugger_url.is_some()
            {
                return Ok(target.clone());
            }
        }

        if let Some(target) = targets.into_iter().find(|t| t.websocket_debugger_url.is_some()) {
            return Ok(target);
        }

        Err("No active browser tab found. Use /navigate or open a website.".to_string())
    }

    /// Resolves a tab strictly by exact `target_id` or `session` alias/host substring.
    pub async fn resolve_strict_target(
        &self,
        target_id: Option<&str>,
        session: Option<&str>,
    ) -> Result<ChromeTarget, String> {
        let targets = self.get_all_targets().await?;
        if let Some(tid) = target_id.filter(|s| !s.trim().is_empty()) {
            return targets
                .into_iter()
                .find(|t| t.id == tid && t.websocket_debugger_url.is_some())
                .ok_or_else(|| format!("No open tab with target_id '{}'. List tabs with GET /tabs.", tid));
        }
        if let Some(s) = session.filter(|s| !s.trim().is_empty()) {
            // Also allow passing a target_id directly inside `session` if it matches an exact tab id
            if let Some(exact) = targets.iter().find(|t| t.id == s && t.websocket_debugger_url.is_some()) {
                return Ok(exact.clone());
            }
            let pat = session_pattern(s);
            return targets
                .into_iter()
                .find(|t| t.url.to_lowercase().contains(&pat) && t.websocket_debugger_url.is_some())
                .ok_or_else(|| format!("No tab open for session '{}'. Open one with POST /tabs/new", s));
        }
        Err("Neither target_id nor session provided".to_string())
    }

    /// Opens a new tab with given URL (optionally in the background without stealing focus).
    pub async fn create_tab_opts(
        &self,
        url: &str,
        background: bool,
        cdp: Option<&CdpClient>,
    ) -> Result<ChromeTarget, String> {
        if background {
            if let Some(client) = cdp {
                if let Ok(res) = client
                    .send_raw_command("Target.createTarget", json!({ "url": url, "background": true }), 5000)
                    .await
                {
                    if let Some(tid) = res.get("result").and_then(|r| r.get("targetId")).and_then(|s| s.as_str()) {
                        tokio::time::sleep(Duration::from_millis(80)).await;
                        if let Ok(targets) = self.get_all_targets().await {
                            if let Some(found) = targets.into_iter().find(|t| t.id == tid) {
                                return Ok(found);
                            }
                        }
                        return Ok(ChromeTarget {
                            id: tid.to_string(),
                            title: String::new(),
                            target_type: "page".to_string(),
                            url: url.to_string(),
                            websocket_debugger_url: Some(format!("ws://127.0.0.1:{}/devtools/page/{}", self.cdp_port, tid)),
                        });
                    }
                }
            }
        }
        self.create_tab(url).await
    }

    /// Opens a new foreground tab with given URL
    pub async fn create_tab(&self, url: &str) -> Result<ChromeTarget, String> {
        let endpoint = format!("http://127.0.0.1:{}/json/new?{}", self.cdp_port, escape_query(url));
        let client = reqwest::Client::new();
        let resp = client.put(&endpoint).send().await
            .map_err(|e| format!("Failed to create tab: {}", e))?;

        let target: ChromeTarget = resp.json().await
            .map_err(|e| format!("Failed to parse new tab target: {}", e))?;

        Ok(target)
    }

    /// Brings tab to focus
    pub async fn activate_tab(&self, target_id: &str) -> Result<(), String> {
        let endpoint = format!("http://127.0.0.1:{}/json/activate/{}", self.cdp_port, target_id);
        let client = reqwest::Client::new();
        client.get(&endpoint).send().await.map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Closes tab
    pub async fn close_tab(&self, target_id: &str) -> Result<(), String> {
        let endpoint = format!("http://127.0.0.1:{}/json/close/{}", self.cdp_port, target_id);
        let client = reqwest::Client::new();
        client.get(&endpoint).send().await.map_err(|e| e.to_string())?;
        Ok(())
    }
}

/// Maps a session name to the URL substring of its tab ("instagram" -> "instagram.com").
pub fn session_pattern(s: &str) -> String {
    let lower = s.trim().to_lowercase();
    match lower.as_str() {
        "gemini" => "gemini.google.com",
        "claude" => "claude.ai",
        "chatgpt" | "openai" => "chatgpt.com",
        "perplexity" => "perplexity.ai",
        "colab" => "colab.research.google.com",
        "meta" => "facebook.com/ads/library",
        "facebook" | "fb" => "facebook.com",
        "x" | "twitter" => "x.com",
        "youtube" => "youtube.com",
        "instagram" => "instagram.com",
        "tiktok" => "tiktok.com",
        "github" => "github.com",
        "reddit" => "reddit.com",
        "linkedin" => "linkedin.com",
        "indeed" => "indeed.",
        "wellfound" | "angellist" => "wellfound.com",
        "avito" => "avito.ma",
        "mubawab" => "mubawab.ma",
        other => other,
    }
    .to_string()
}

/// Percent-encodes every byte that is not an unreserved URL character.
fn escape_query(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => (b as char).to_string(),
            _ => format!("%{:02X}", b),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{escape_query, session_pattern};

    #[test]
    fn escape_query_keeps_nothing_chrome_would_split_on() {
        assert_eq!(escape_query("https://a.ma/x?p=1&q=é#f"), "https%3A%2F%2Fa.ma%2Fx%3Fp%3D1%26q%3D%C3%A9%23f");
    }

    #[test]
    fn session_pattern_maps_aliases() {
        assert_eq!(session_pattern("instagram"), "instagram.com");
        assert_eq!(session_pattern("Gemini"), "gemini.google.com");
        assert_eq!(session_pattern("linkedin"), "linkedin.com");
        assert_eq!(session_pattern("example.org"), "example.org");
    }
}
