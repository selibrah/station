#!/usr/bin/env python3
"""End-to-end Differential Parity, Causal DOM, MCP Wire & Accessibility Verification
for `landing/index.html` + `landing/station-kernels.js` + `landing/studio-lab.js`.

Proves—without mocks and using zero third-party Python packages—that:
  1. `scripts/sync_landing_kernels.py --check` passes (zero source drift vs `dom.rs` / `mcp.rs`).
  2. When a compiled `station` binary is present, its live `station mcp` stdio `tools/list`
     output matches `window.__stationLandingLab` / `StationKernels.MCP.tools` identically.
  3. On an UNSEEN adversarial HTML document (never present in `landing/`), the landing page's
     live `#studio` workspace produces:
       - Exact `@e1..@eN` element refs, roles, labels, and hrefs matching the `dom.rs` oracle
       - Exact Clean Markdown (`/read`) output & `__NEXT_DATA__` stripping matching the oracle
       - Real React-controlled `<input>` mutation in `<iframe id="target-browser-frame">`
       - Real `File` attachment on `<input type="file">` via `DataTransfer` (`files.length == 1`)
       - Real relational `ON CONFLICT(uid) DO UPDATE` upsert, deduplication, and histogram update
       - Zero `console.error` / uncaught page exceptions, full accessible form/button labeling, and CLS < 0.01.
"""
import base64
import functools
import http.server
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANDING_DIR = os.path.join(ROOT, "landing")
SYNC_SCRIPT = os.path.join(ROOT, "scripts", "sync_landing_kernels.py")

# Unseen adversarial HTML document — never shipped inside `landing/`.
# Tests: <nav> & #cookie-banner stripping, [aria-hidden="true"] trap exclusion,
# nested <a><span> deduplication, __NEXT_DATA__ bloat stripping, controlled <input>,
# <input type="file">, and $240,000 salary extraction.
UNSEEN_BLOAT = json.dumps({"hydration": ["chunk_" + str(i) * 40 for i in range(120)]})
UNSEEN_ADVERSARIAL_HTML = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <base href="https://careers.cloudflare.com/jobs/99182-principal-rust">
  <title>Principal Rust Edge Runtime Engineer — Cloudflare ($240,000 Remote)</title>
</head>
<body>
  <nav>Cloudflare Global Nav · Products · Pricing · Docs</nav>
  <div id="cookie-banner" class="cookie-banner">Accept analytics cookies</div>
  <div aria-hidden="true"><button type="button">Hidden Bot Honeypot</button></div>
  <main>
    <h1>Principal Rust Edge Runtime Engineer</h1>
    <p>Location: <strong>Remote</strong> · Compensation: <strong>$240,000</strong> USD · Stack: <code>Rust</code>, <code>Tokio</code>, <code>CDP</code>, <code>SQLite</code>.</p>
    <ul>
      <li>Design zero-copy WebSocket multiplexers and isolated browser sandboxes</li>
      <li>Read the <a href="/systems/whitepaper"><span>Edge Runtime Whitepaper</span></a></li>
    </ul>
    <form onsubmit="event.preventDefault();">
      <label for="adv-input">Candidate GitHub</label>
      <input id="adv-input" type="text" value="initial_handle">
      <button id="adv-toggle" type="button" onclick="this.setAttribute('data-clicked', 'yes')">Confirm Distributed Systems</button>
      <label for="adv-file">Attach Architecture Sample PDF</label>
      <input id="adv-file" type="file" accept=".pdf">
    </form>
  </main>
  <footer>Copyright Cloudflare</footer>
  <script id="__NEXT_DATA__" type="application/json">{UNSEEN_BLOAT}</script>
  <script>
    window.__advInputEvents = 0;
    document.getElementById("adv-input").addEventListener("input", function () {{
      window.__advInputEvents += 1;
    }});
  </script>
</body>
</html>
"""


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def find_chrome_binary() -> str:
    for env_key in ("CHROME_BIN", "CHROME_PATH"):
        env_bin = os.environ.get(env_key)
        if env_bin and os.path.exists(env_bin):
            return env_bin
    candidates = [
        "google-chrome",
        "google-chrome-stable",
        "chromium-browser",
        "chromium",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
    ]
    for c in candidates:
        resolved = c if os.path.isabs(c) else shutil.which(c)
        if resolved and os.path.exists(resolved):
            return resolved
    raise RuntimeError("No Chrome/Chromium binary found for headless differential test.")


class MinimalLoopbackWs:
    """RFC-6455 loopback WebSocket client using only Python stdlib (`socket` + `struct`)."""

    def __init__(self, ws_url: str):
        parsed = urllib.parse.urlparse(ws_url)
        host = parsed.hostname or "127.0.0.1"
        port = parsed.port or 80
        path = parsed.path + (("?" + parsed.query) if parsed.query else "")

        self.sock = socket.create_connection((host, port), timeout=15)
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(req.encode("ascii"))
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("WebSocket handshake EOF")
            buf += chunk
        header, self._leftover = buf.split(b"\r\n\r\n", 1)
        if b"101" not in header.splitlines()[0]:
            raise RuntimeError(f"WebSocket upgrade failed: {header.decode('latin1', 'replace')}")
        self._next_id = 1
        self.events = []

    def _recv_exact(self, n: int) -> bytes:
        out = bytearray()
        if self._leftover:
            take = min(n, len(self._leftover))
            out.extend(self._leftover[:take])
            self._leftover = self._leftover[take:]
        while len(out) < n:
            chunk = self.sock.recv(max(4096, n - len(out)))
            if not chunk:
                raise RuntimeError("Unexpected EOF reading WebSocket frame")
            if len(out) + len(chunk) > n:
                need = n - len(out)
                out.extend(chunk[:need])
                self._leftover = chunk[need:] + self._leftover
            else:
                out.extend(chunk)
        return bytes(out)

    def send_json(self, obj: dict):
        data = json.dumps(obj).encode("utf-8")
        mask_key = os.urandom(4)
        header = bytearray([0x81])  # FIN + text frame
        n = len(data)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", n))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", n))
        header.extend(mask_key)
        masked = bytes(b ^ mask_key[i % 4] for i, b in enumerate(data))
        self.sock.sendall(bytes(header) + masked)

    def recv_json(self) -> dict:
        while True:
            b0, b1 = self._recv_exact(2)
            opcode = b0 & 0x0F
            masked = (b1 & 0x80) != 0
            length = b1 & 0x7F
            if length == 126:
                (length,) = struct.unpack("!H", self._recv_exact(2))
            elif length == 127:
                (length,) = struct.unpack("!Q", self._recv_exact(8))
            mask_key = self._recv_exact(4) if masked else b""
            payload = self._recv_exact(length)
            if masked:
                payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:
                raise RuntimeError("WebSocket closed by peer")
            if opcode == 0x9:  # ping -> pong
                pong = bytearray([0x8A, 0x80]) + os.urandom(4)
                self.sock.sendall(bytes(pong))
                continue
            if opcode in (0x1, 0x2):
                return json.loads(payload.decode("utf-8"))

    def call(self, method: str, params: dict = None) -> dict:
        msg_id = self._next_id
        self._next_id += 1
        self.send_json({"id": msg_id, "method": method, "params": params or {}})
        while True:
            msg = self.recv_json()
            if msg.get("id") == msg_id:
                if "error" in msg:
                    raise RuntimeError(f"CDP error on {method}: {msg['error']}")
                return msg.get("result", {})
            self.events.append(msg)

    def eval_js(self, expression: str, await_promise: bool = True):
        res = self.call(
            "Runtime.evaluate",
            {
                "expression": expression,
                "returnByValue": True,
                "awaitPromise": await_promise,
            },
        )
        if "exceptionDetails" in res:
            raise RuntimeError(f"JS exception: {json.dumps(res['exceptionDetails'])}")
        return res.get("result", {}).get("value")

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


class LabRequestHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/__unseen_adversarial.html":
            body = UNSEEN_ADVERSARIAL_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return
        super().do_GET()

    def log_message(self, fmt, *args):
        pass


def verify_mcp_binary_if_present(kernels_tools: list):
    candidates = [
        os.path.join(ROOT, "daemon", "target", "release", "station"),
        os.path.join(ROOT, "daemon", "target", "debug", "station"),
    ]
    station_bin = next((p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)), None)
    if not station_bin:
        print("INFO: Compiled `station` binary not yet in target/{release,debug}; skipping live stdio check.")
        return

    req = json.dumps({"jsonrpc": "2.0", "id": 77, "method": "tools/list", "params": {}}) + "\n"
    proc = subprocess.run(
        [station_bin, "mcp"],
        input=req,
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert proc.returncode == 0, f"`station mcp` exited {proc.returncode}: {proc.stderr}"
    line = proc.stdout.strip().splitlines()[0]
    reply = json.loads(line)
    live_tools = reply["result"]["tools"]
    assert live_tools == kernels_tools, "Mismatch between live `station mcp` binary tools/list and landing/station-kernels.js!"
    print(f"PASS [1b]: Live `{os.path.basename(station_bin)} mcp` stdio tools/list ({len(live_tools)} tools) == station-kernels.js")


def main() -> int:
    # 1. Verify zero source drift between daemon/src/{dom,mcp}.rs and landing/station-kernels.js
    subprocess.check_call([sys.executable, SYNC_SCRIPT, "--check"])
    print("PASS [1a]: sync_landing_kernels.py --check verified zero drift.")

    # Load extracted StationKernels via node to get oracle JS strings & MCP tool schemas
    node_dump = subprocess.check_output(
        [
            "node",
            "-e",
            "const K = require(process.argv[1]); console.log(JSON.stringify({ snap: K.buildSnapshotJs(false, 120), read: K.buildReadJs(40000), tools: K.MCP.tools }));",
            os.path.join(LANDING_DIR, "station-kernels.js"),
        ],
        text=True,
    )
    oracle_bundle = json.loads(node_dump)
    verify_mcp_binary_if_present(oracle_bundle["tools"])

    # 2. Start local HTTP server serving `landing/` + `/__unseen_adversarial.html`
    http_port = find_free_port()
    handler = functools.partial(LabRequestHandler, directory=LANDING_DIR)
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", http_port), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    # 3. Acquire CDP Browser Endpoint:
    #    - First try spawning an isolated headless Chrome instance (standard on Linux CI).
    #    - If OS seatbelt blocks spawning a new GUI/Mach Chrome binary (macOS subshell),
    #      attach non-destructively to existing 127.0.0.1:9222 via background Target.createTarget.
    cdp_port = find_free_port()
    chrome_bin = find_chrome_binary()
    user_dir = tempfile.mkdtemp(prefix="station-parity-")
    stderr_log_path = os.path.join(user_dir, "chrome_stderr.log")
    stderr_f = open(stderr_log_path, "w", encoding="utf-8")
    chrome_proc = subprocess.Popen(
        [
            chrome_bin,
            "--headless=new",
            "--no-sandbox",
            "--disable-setuid-sandbox",
            "--disable-gpu",
            "--disable-dev-shm-usage",
            "--no-first-run",
            "--no-default-browser-check",
            "--window-size=1440,960",
            "--remote-debugging-address=127.0.0.1",
            f"--remote-debugging-port={cdp_port}",
            "--remote-allow-origins=*",
            f"--user-data-dir={user_dir}",
            "about:blank",
        ],
        stdout=subprocess.DEVNULL,
        stderr=stderr_f,
    )

    browser_ws_url = None
    created_target_ids = []
    ws_browser = None

    try:
        for _ in range(55):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{cdp_port}/json/version", timeout=0.6) as r:
                    ver = json.loads(r.read().decode("utf-8"))
                    browser_ws_url = ver.get("webSocketDebuggerUrl")
                    if browser_ws_url:
                        break
            except Exception:
                pass
            if chrome_proc.poll() is not None:
                break
            time.sleep(0.2)

        if not browser_ws_url:
            # Fallback to active local Chrome CDP on 9222 (macOS GUI subshell seatbelt)
            try:
                with urllib.request.urlopen("http://127.0.0.1:9222/json/version", timeout=2) as r:
                    ver = json.loads(r.read().decode("utf-8"))
                    browser_ws_url = ver["webSocketDebuggerUrl"]
                    cdp_port = 9222
            except Exception as exc:
                stderr_f.flush()
                err_txt = open(stderr_log_path, "r", encoding="utf-8", errors="replace").read()
                raise RuntimeError(
                    f"Headless Chrome ({chrome_bin}) failed to expose CDP on port {cdp_port} "
                    f"(exit={chrome_proc.poll()}):\n{err_txt}"
                ) from exc

        ws_browser = MinimalLoopbackWs(browser_ws_url)
        t_landing = ws_browser.call(
            "Target.createTarget",
            {"url": f"http://127.0.0.1:{http_port}/index.html", "background": True},
        )["targetId"]
        created_target_ids.append(t_landing)

        t_oracle = ws_browser.call(
            "Target.createTarget",
            {"url": f"http://127.0.0.1:{http_port}/__unseen_adversarial.html", "background": True},
        )["targetId"]
        created_target_ids.append(t_oracle)

        # Resolve per-page debugger WebSocket URLs
        landing_ws_url = f"ws://127.0.0.1:{cdp_port}/devtools/page/{t_landing}"
        oracle_ws_url = f"ws://127.0.0.1:{cdp_port}/devtools/page/{t_oracle}"

        ws_landing = MinimalLoopbackWs(landing_ws_url)
        ws_oracle = MinimalLoopbackWs(oracle_ws_url)

        for ws in (ws_landing, ws_oracle):
            ws.call("Runtime.enable")
            ws.call("Page.enable")

        # Wait until both documents have committed navigation & __stationLandingLab is booted
        for _ in range(60):
            r1 = ws_oracle.eval_js("document.readyState === 'complete' && location.href.includes('__unseen_adversarial.html')")
            r2 = ws_landing.eval_js("Boolean(window.__stationLandingLab && window.__stationLandingLab.getState().lastSnapshot)")
            if r1 is True and r2 is True:
                break
            time.sleep(0.15)
        else:
            raise RuntimeError("Timed out waiting for landing page lab initialization")

        # Install CLS observer on landing page before running interactions
        ws_landing.eval_js("""
            window.__clsTotal = 0;
            if (window.PerformanceObserver) {
                new PerformanceObserver((list) => {
                    for (const entry of list.getEntries()) {
                        if (!entry.hadRecentInput) window.__clsTotal += entry.value;
                    }
                }).observe({ type: 'layout-shift', buffered: true });
            }
        """)

        # 4. Run Oracle kernels directly on Tab A (`/__unseen_adversarial.html`)
        oracle_snap = ws_oracle.eval_js(oracle_bundle["snap"])
        oracle_read = ws_oracle.eval_js(oracle_bundle["read"])

        # 5. Feed the EXACT SAME unseen HTML into Landing Page's `#studio` custom HTML flow!
        landing_mount = ws_landing.eval_js(
            f"window.__stationLandingLab.mountCustomHtml({json.dumps(UNSEEN_ADVERSARIAL_HTML)})"
        )
        landing_snap = landing_mount["snapshot"]
        landing_read = ws_landing.eval_js("window.__stationLandingLab.runRead(40000)")

        # Compare @e1..@eN structural identity (excluding viewport-width-dependent rect x/y)
        def norm_elements(elems):
            return [
                {
                    "ref": e["ref"],
                    "tag": e["tag"],
                    "role": e["role"],
                    "label": e["label"],
                    "type": e.get("type"),
                    "value": e.get("value"),
                    "href": e.get("href"),
                }
                for e in elems
            ]

        assert norm_elements(landing_snap["elements"]) == norm_elements(oracle_snap["elements"]), (
            f"@eN Snapshot mismatch!\nLanding: {norm_elements(landing_snap['elements'])}\nOracle:  {norm_elements(oracle_snap['elements'])}"
        )
        # Verify hidden [aria-hidden="true"] bot honeypot was excluded
        labels = [e["label"] for e in landing_snap["elements"]]
        assert "Hidden Bot Honeypot" not in labels, "aria-hidden trap leaked into @eN snapshot!"
        print(f"PASS [2]: Unseen HTML @eN Snapshot parity ({len(labels)} refs: {labels})")

        # Compare Clean Markdown extraction & __NEXT_DATA__ stripping
        assert landing_read["markdown"] == oracle_read["markdown"], (
            f"Clean Markdown mismatch!\nLanding:\n{landing_read['markdown']}\nOracle:\n{oracle_read['markdown']}"
        )
        assert landing_read["structured_data"]["has_next_data"] is True
        assert "Accept analytics cookies" not in landing_read["markdown"], "Cookie banner was not stripped!"
        assert "Cloudflare Global Nav" not in landing_read["markdown"], "<nav> noise was not stripped!"
        print(f"PASS [3]: Unseen HTML Clean Markdown parity (-{landing_read['token_savings_pct']}% tokens, __NEXT_DATA__ stripped)")

        # 6. Verify Causal Act (`fill` & `click`) mutates the live `<iframe id="target-browser-frame">` DOM!
        input_ref = "@" + next(e["ref"] for e in landing_snap["elements"] if e["tag"] == "input" and e.get("type") == "text")
        btn_ref = "@" + next(e["ref"] for e in landing_snap["elements"] if e["tag"] == "button")
        file_ref = "@" + next(e["ref"] for e in landing_snap["elements"] if e.get("type") == "file")

        act_fill = ws_landing.eval_js(
            f"window.__stationLandingLab.runAct({{ action: 'fill', target: {json.dumps(input_ref)}, value: 'selibrah_edge_rust' }})"
        )
        assert act_fill["ok"] is True
        iframe_check = ws_landing.eval_js("""(() => {
            const f = document.getElementById('target-browser-frame');
            return {
                val: f.contentDocument.getElementById('adv-input').value,
                events: f.contentWindow.__advInputEvents
            };
        })()""")
        assert iframe_check["val"] == "selibrah_edge_rust" and iframe_check["events"] >= 1, f"Controlled input did not sync: {iframe_check}"

        act_click = ws_landing.eval_js(
            f"window.__stationLandingLab.runAct({{ action: 'click', target: {json.dumps(btn_ref)}, value: '' }})"
        )
        assert act_click["ok"] is True
        clicked_attr = ws_landing.eval_js("document.getElementById('target-browser-frame').contentDocument.getElementById('adv-toggle').getAttribute('data-clicked')")
        assert clicked_attr == "yes", "Button click inside iframe did not fire onclick handler!"
        print(f"PASS [4]: Causal build_act_js fill ({input_ref}) & click ({btn_ref}) mutated live target iframe DOM.")

        # 7. Verify Gesture-Free File Upload (`DataTransfer` -> `<input type="file">.files[0]`)
        up_res = ws_landing.eval_js(
            f"window.__stationLandingLab.runUpload({json.dumps(file_ref)}, 'architecture_sample.pdf', 24576)"
        )
        assert up_res["ok"] is True and up_res["count"] == 1
        live_files = ws_landing.eval_js("""(() => {
            const inp = document.getElementById('target-browser-frame').contentDocument.getElementById('adv-file');
            return Array.from(inp.files).map(f => ({ name: f.name, size: f.size, type: f.type }));
        })()""")
        assert live_files == [{"name": "architecture_sample.pdf", "size": 24576, "type": "application/pdf"}], (
            f"Unexpected iframe input.files state: {live_files}"
        )
        print("PASS [5]: Gesture-free DataTransfer upload attached real 24,576-byte PDF to <input type='file'>.")

        # 8. Verify Harvest -> Relational FindingsDB UPSERT, Deduplication & Histogram Math
        rows_before = len(ws_landing.eval_js("window.__stationLandingLab.getFindingsRows()"))
        h1 = ws_landing.eval_js("window.__stationLandingLab.harvestCurrentTab()")
        rows_after_1 = len(ws_landing.eval_js("window.__stationLandingLab.getFindingsRows()"))
        h2 = ws_landing.eval_js("window.__stationLandingLab.harvestCurrentTab()")
        rows_after_2 = len(ws_landing.eval_js("window.__stationLandingLab.getFindingsRows()"))

        assert h1["isNew"] is True and h1["amount"] == 240000 and h1["currency"] == "$" and h1["score"] >= 85, f"Unexpected harvest 1: {h1}"
        assert rows_after_1 == rows_before + 1, "Expected +1 row on initial INSERT"
        assert h2["isNew"] is False and rows_after_2 == rows_after_1, "Expected ON CONFLICT(uid) deduplication on second harvest"
        hist = ws_landing.eval_js("window.__stationLandingLab.computeHistogram('jobs')")
        assert sum(b["count"] for b in hist["bins"]) >= 5 and hist["median"] >= 195000, f"Invalid histogram: {hist}"
        print(f"PASS [6]: Harvest UPSERT & deduplication verified (uid={h1['uid']}, amount=${h1['amount']:,}, score={h1['score']}).")

        # 9. Accessibility, Console Error & Layout Shift (CLS) Audit
        a11y_and_cls = ws_landing.eval_js("""(() => {
            const unlabeledControls = [];
            document.querySelectorAll('input, select, textarea').forEach(el => {
                if (el.type === 'hidden') return;
                const hasFor = el.id && document.querySelector(`label[for="${CSS.escape(el.id)}"]`);
                const hasWrap = el.closest('label');
                const hasAria = el.getAttribute('aria-label') || el.getAttribute('aria-labelledby');
                if (!hasFor && !hasWrap && !hasAria) unlabeledControls.push(el.outerHTML.slice(0, 80));
            });
            const emptyButtons = [];
            document.querySelectorAll('button').forEach(b => {
                const txt = (b.innerText || b.textContent || b.getAttribute('aria-label') || '').trim();
                if (!txt) emptyButtons.push(b.outerHTML.slice(0, 80));
            });
            const iframeTitle = document.getElementById('target-browser-frame')?.getAttribute('title') || '';
            return {
                unlabeledControls,
                emptyButtons,
                hasIframeTitle: iframeTitle.length > 0,
                cls: window.__clsTotal || 0
            };
        })()""")

        assert not a11y_and_cls["unlabeledControls"], f"Unlabeled form controls: {a11y_and_cls['unlabeledControls']}"
        assert not a11y_and_cls["emptyButtons"], f"Empty buttons: {a11y_and_cls['emptyButtons']}"
        assert a11y_and_cls["hasIframeTitle"] is True, "Missing iframe title"
        assert a11y_and_cls["cls"] < 0.01, f"Cumulative Layout Shift too high: {a11y_and_cls['cls']}"

        console_errors = [
            ev for ev in ws_landing.events
            if ev.get("method") == "Runtime.exceptionThrown"
            or (ev.get("method") == "Runtime.consoleAPICalled" and ev.get("params", {}).get("type") == "error")
        ]
        assert not console_errors, f"Console/page errors detected on landing page: {console_errors}"
        print(f"PASS [7]: Zero console/page errors, 0 unlabeled controls, CLS = {a11y_and_cls['cls']:.4f}.")

        ws_landing.close()
        ws_oracle.close()
        print("\nALL 7 DIFFERENTIAL PARITY & CAUSAL CHECKS PASSED!")
        return 0
    finally:
        if ws_browser:
            for tid in created_target_ids:
                try:
                    ws_browser.call("Target.closeTarget", {"targetId": tid})
                except Exception:
                    pass
            ws_browser.close()
        chrome_proc.terminate()
        try:
            chrome_proc.wait(timeout=3)
        except Exception:
            chrome_proc.kill()
        stderr_f.close()
        httpd.shutdown()
        shutil.rmtree(user_dir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
