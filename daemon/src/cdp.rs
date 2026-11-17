use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::sync::{mpsc, oneshot, Mutex};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

pub struct CdpClient {
    next_id: AtomicU64,
    cmd_tx: mpsc::Sender<(Value, oneshot::Sender<Result<Value, String>>)>,
    alive: Arc<AtomicBool>,
}

/// Persistent pool of CDP WebSocket clients keyed by Chrome `target_id`.
/// Gives background/secondary tabs the same sub-ms persistent WebSocket latency as the main tab.
pub struct CdpTabPool {
    entries: Mutex<HashMap<String, (String, Arc<CdpClient>)>>,
}

impl CdpTabPool {
    pub fn new() -> Self {
        Self {
            entries: Mutex::new(HashMap::new()),
        }
    }

    pub async fn get_or_connect(&self, target_id: &str, ws_url: &str) -> Result<Arc<CdpClient>, String> {
        {
            let mut map = self.entries.lock().await;
            if let Some((saved_url, client)) = map.get(target_id) {
                if saved_url == ws_url && client.is_alive() {
                    return Ok(Arc::clone(client));
                }
                map.remove(target_id);
            }
            // Opportunistically prune dead sockets so pool stays tiny
            map.retain(|_, (_, c)| c.is_alive());
        }

        let client = Arc::new(CdpClient::connect_pinned(ws_url.to_string()).await?);
        let mut map = self.entries.lock().await;
        map.insert(target_id.to_string(), (ws_url.to_string(), Arc::clone(&client)));
        Ok(client)
    }

    pub async fn remove(&self, target_id: &str) {
        self.entries.lock().await.remove(target_id);
    }

    pub async fn active_count(&self) -> usize {
        let mut map = self.entries.lock().await;
        map.retain(|_, (_, c)| c.is_alive());
        map.len()
    }
}

/// Picks the tab whose URL contains `prefer_host` (the host the daemon was started on); falls back to the first page.
async fn resolve_active_ws_url(cdp_port: u16, prefer_host: &str) -> Option<String> {
    let url = format!("http://127.0.0.1:{}/json", cdp_port);
    let client = reqwest::Client::builder()
        .timeout(Duration::from_millis(500))
        .build()
        .ok()?;
    let resp = client.get(&url).send().await.ok()?;
    let targets: Vec<Value> = resp.json().await.ok()?;
    let pages: Vec<(&str, &str)> = targets.iter()
        .filter(|t| t.get("type").and_then(|s| s.as_str()) == Some("page"))
        .filter_map(|t| Some((
            t.get("url").and_then(|s| s.as_str()).unwrap_or(""),
            t.get("webSocketDebuggerUrl").and_then(|s| s.as_str())?,
        )))
        .collect();
    pages.iter().find(|(url, _)| !prefer_host.is_empty() && url.contains(prefer_host))
        .or_else(|| pages.first())
        .map(|(_, ws)| ws.to_string())
}

const NOT_SENT: &str = "WebSocket send error";
const NO_TAB: &str = "No browser tab to talk to: the browser window is closed or the browser is not running. Open a tab and try again";
/// A reconnect to another tab takes a moment and waiting commands ride it out; past this there is no tab.
const RECONNECT_GRACE: Duration = Duration::from_secs(3);

impl CdpClient {
    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::Relaxed)
    }

    /// Persistent auto-reconnecting socket for the daemon's main tab.
    pub async fn connect(cdp_port: u16, ws_url: String, prefer_host: String) -> Result<Self, String> {
        let (cmd_tx, mut cmd_rx) = mpsc::channel::<(Value, oneshot::Sender<Result<Value, String>>)>(64);
        let alive = Arc::new(AtomicBool::new(true));
        let alive_bg = Arc::clone(&alive);
        let mut target_ws_url = ws_url;

        tokio::spawn(async move {
            let pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value, String>>>>> =
                Arc::new(Mutex::new(HashMap::new()));

            let mut down_since: Option<std::time::Instant> = None;
            loop {
                if let Some(fresh_ws) = resolve_active_ws_url(cdp_port, &prefer_host).await {
                    target_ws_url = fresh_ws;
                }

                match connect_async(&target_ws_url).await {
                    Ok((ws_stream, _)) => {
                        alive_bg.store(true, Ordering::Relaxed);
                        down_since = None;
                        let (mut write, mut read) = ws_stream.split();
                        let pending_for_read = Arc::clone(&pending);

                        let mut reader_handle = tokio::spawn(async move {
                            while let Some(msg_res) = read.next().await {
                                match msg_res {
                                    Ok(Message::Text(text)) => {
                                        if let Ok(v) = serde_json::from_str::<Value>(&text) {
                                            if let Some(id) = v.get("id").and_then(|i| i.as_u64()) {
                                                let mut map = pending_for_read.lock().await;
                                                if let Some(tx) = map.remove(&id) {
                                                    let _ = tx.send(Ok(v));
                                                }
                                            }
                                        }
                                    }
                                    Ok(Message::Close(_)) | Err(_) => break,
                                    _ => {}
                                }
                            }
                        });

                        let mut keep_running = true;
                        while keep_running {
                            tokio::select! {
                                maybe_cmd = cmd_rx.recv() => {
                                    match maybe_cmd {
                                        Some((msg, resp_tx)) => {
                                            let id = msg.get("id").and_then(|i| i.as_u64()).unwrap_or(0);
                                            {
                                                let mut map = pending.lock().await;
                                                map.insert(id, resp_tx);
                                            }
                                            if let Err(e) = write.send(Message::Text(msg.to_string())).await {
                                                let mut map = pending.lock().await;
                                                if let Some(tx) = map.remove(&id) {
                                                    let _ = tx.send(Err(format!("{}: {}", NOT_SENT, e)));
                                                }
                                                keep_running = false;
                                            }
                                        }
                                        None => return,
                                    }
                                }
                                _ = &mut reader_handle => { keep_running = false; }
                            }
                        }

                        reader_handle.abort();
                        for (_, tx) in pending.lock().await.drain() {
                            let _ = tx.send(Err("CDP connection closed before a reply".to_string()));
                        }
                    }
                    Err(_) => {
                        let since = *down_since.get_or_insert_with(std::time::Instant::now);
                        let retry = tokio::time::sleep(Duration::from_millis(400));
                        tokio::pin!(retry);
                        loop {
                            tokio::select! {
                                _ = &mut retry => break,
                                maybe_cmd = cmd_rx.recv(), if since.elapsed() >= RECONNECT_GRACE => {
                                    match maybe_cmd {
                                        Some((_, tx)) => { let _ = tx.send(Err(NO_TAB.to_string())); }
                                        None => return,
                                    }
                                }
                            }
                        }
                    }
                }
            }
        });

        Ok(Self {
            next_id: AtomicU64::new(1),
            cmd_tx,
            alive,
        })
    }

    /// Persistent socket pinned to a single secondary tab (`CdpTabPool`). Marks itself dead when the tab closes.
    pub async fn connect_pinned(ws_url: String) -> Result<Self, String> {
        let (ws_stream, _) = connect_async(&ws_url)
            .await
            .map_err(|e| format!("Failed to connect to tab WebSocket: {}", e))?;

        let (cmd_tx, mut cmd_rx) = mpsc::channel::<(Value, oneshot::Sender<Result<Value, String>>)>(32);
        let alive = Arc::new(AtomicBool::new(true));
        let alive_bg = Arc::clone(&alive);

        tokio::spawn(async move {
            let pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value, String>>>>> =
                Arc::new(Mutex::new(HashMap::new()));
            let (mut write, mut read) = ws_stream.split();
            let pending_for_read = Arc::clone(&pending);

            let mut reader_handle = tokio::spawn(async move {
                while let Some(msg_res) = read.next().await {
                    match msg_res {
                        Ok(Message::Text(text)) => {
                            if let Ok(v) = serde_json::from_str::<Value>(&text) {
                                if let Some(id) = v.get("id").and_then(|i| i.as_u64()) {
                                    let mut map = pending_for_read.lock().await;
                                    if let Some(tx) = map.remove(&id) {
                                        let _ = tx.send(Ok(v));
                                    }
                                }
                            }
                        }
                        Ok(Message::Close(_)) | Err(_) => break,
                        _ => {}
                    }
                }
            });

            loop {
                tokio::select! {
                    maybe_cmd = cmd_rx.recv() => {
                        match maybe_cmd {
                            Some((msg, resp_tx)) => {
                                let id = msg.get("id").and_then(|i| i.as_u64()).unwrap_or(0);
                                {
                                    let mut map = pending.lock().await;
                                    map.insert(id, resp_tx);
                                }
                                if let Err(e) = write.send(Message::Text(msg.to_string())).await {
                                    let mut map = pending.lock().await;
                                    if let Some(tx) = map.remove(&id) {
                                        let _ = tx.send(Err(format!("{}: {}", NOT_SENT, e)));
                                    }
                                    break;
                                }
                            }
                            None => break,
                        }
                    }
                    _ = &mut reader_handle => break,
                }
            }

            alive_bg.store(false, Ordering::Relaxed);
            reader_handle.abort();
            for (_, tx) in pending.lock().await.drain() {
                let _ = tx.send(Err("Tab closed before a reply".to_string()));
            }
        });

        Ok(Self {
            next_id: AtomicU64::new(1),
            cmd_tx,
            alive,
        })
    }

    /// Execute raw Chrome DevTools Protocol method
    pub async fn send_raw_command(
        &self,
        method: &str,
        params: Value,
        timeout_ms: u64,
    ) -> Result<Value, String> {
        match self.send_once(method, params.clone(), timeout_ms).await {
            Err(e) if e.starts_with(NOT_SENT) => {
                tokio::time::sleep(Duration::from_millis(250)).await;
                self.send_once(method, params, timeout_ms).await
            }
            other => other,
        }
    }

    async fn send_once(&self, method: &str, params: Value, timeout_ms: u64) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let req = json!({
            "id": id,
            "method": method,
            "params": params,
        });

        let (tx, rx) = oneshot::channel();
        let exchange = async {
            self.cmd_tx
                .send((req, tx))
                .await
                .map_err(|e| format!("Failed to dispatch command to CDP channel: {}", e))?;
            rx.await.map_err(|_| "CDP channel sender dropped".to_string())?
        };
        tokio::time::timeout(Duration::from_millis(timeout_ms), exchange)
            .await
            .unwrap_or_else(|_| Err(format!("CDP command timed out after {}ms", timeout_ms)))
    }

    /// Evaluates JavaScript expression via Runtime.evaluate
    pub async fn eval_js(&self, code: &str, timeout_ms: u64) -> Result<Value, String> {
        let params = json!({
            "expression": code,
            "returnByValue": true,
            "awaitPromise": true,
            "userGesture": true,
        });

        let resp = self.send_raw_command("Runtime.evaluate", params, timeout_ms).await?;
        extract_eval_result(&resp)
    }

    /// Navigate tab to a new URL reliably via window.location.href
    pub async fn navigate(&self, url: &str) -> Result<Value, String> {
        if !url.trim().to_ascii_lowercase().starts_with("http") {
            return Err("Only http(s) URLs are allowed".to_string());
        }
        let escaped = serde_json::to_string(url).unwrap_or_else(|_| "\"\"".to_string());
        let js = format!("window.location.href = {}; 'navigating'", escaped);
        self.eval_js(&js, 10000).await
    }

    /// Capture page screenshot as base64 via CDP Page.captureScreenshot
    #[allow(dead_code)]
    pub async fn capture_screenshot(&self) -> Result<String, String> {
        self.capture_screenshot_opts("png", false).await
    }

    pub async fn capture_screenshot_opts(&self, format: &str, full_page: bool) -> Result<String, String> {
        let fmt = match format.to_ascii_lowercase().as_str() {
            "jpg" | "jpeg" => "jpeg",
            "webp" => "webp",
            _ => "png",
        };
        let mut params = json!({
            "format": fmt,
            "fromSurface": true,
            "captureBeyondViewport": full_page,
        });
        if fmt != "png" {
            params["quality"] = json!(85);
        }
        let resp = self.send_raw_command("Page.captureScreenshot", params, 15000).await?;
        if let Some(data) = resp.get("result").and_then(|r| r.get("data")).and_then(|d| d.as_str()) {
            Ok(data.to_string())
        } else if let Some(err) = resp.get("error").and_then(|e| e.get("message")).and_then(|m| m.as_str()) {
            Err(err.to_string())
        } else {
            Err("Failed to capture screenshot data from CDP".to_string())
        }
    }
}

/// Turns a Runtime.evaluate reply into the JS value, or the CDP error / thrown exception.
pub fn extract_eval_result(resp: &Value) -> Result<Value, String> {
    if let Some(err) = resp.get("error") {
        let msg = err.get("message").and_then(|m| m.as_str()).unwrap_or("Unknown CDP error");
        return Err(msg.to_string());
    }

    let result_obj = resp.get("result").ok_or_else(|| "Missing result in CDP response".to_string())?;
    if let Some(ex) = result_obj.get("exceptionDetails") {
        let desc = ex.get("exception")
            .and_then(|e| e.get("description"))
            .and_then(|d| d.as_str())
            .unwrap_or("JavaScript exception thrown");
        return Err(desc.to_string());
    }

    if let Some(inner) = result_obj.get("result") {
        if let Some(val) = inner.get("value") {
            return Ok(val.clone());
        }
        if let Some(t) = inner.get("type").and_then(|s| s.as_str()) {
            if t == "undefined" {
                return Ok(Value::Null);
            }
        }
    }

    Ok(Value::Null)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn no_tab_fails_fast_instead_of_hanging() {
        let cdp = Arc::new(CdpClient::connect(1, "ws://127.0.0.1:1/devtools/page/gone".to_string(), String::new()).await.unwrap());
        let started = std::time::Instant::now();
        let calls: Vec<_> = (0..100).map(|_| {
            let cdp = Arc::clone(&cdp);
            tokio::spawn(async move { cdp.send_raw_command("Runtime.evaluate", json!({}), 60_000).await })
        }).collect();
        for call in calls {
            assert_eq!(call.await.unwrap(), Err(NO_TAB.to_string()));
        }
        assert!(started.elapsed() < Duration::from_secs(10), "took {:?}", started.elapsed());
    }
}
