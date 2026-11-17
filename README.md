# Station

**Your real logged-in Chrome as a `0.36 ms` CLI & native MCP server — in one 4.5 MB Rust binary, plus a native Swift 6 macOS Studio app.**

[![Download Station Studio for macOS](https://img.shields.io/badge/Download-Station%20Studio%20macOS%20(.dmg)-0F52BA?style=for-the-badge&logo=apple)](https://github.com/selibrah/station/releases/latest/download/Station-Studio-v0.4.0-macOS-arm64.dmg)
[![Standalone CLI](https://img.shields.io/badge/CLI%20%2B%20MCP-macos--arm64.tar.gz-10B981?style=for-the-badge&logo=rust)](https://github.com/selibrah/station/releases/latest/download/station-cli-v0.4.0-macos-arm64.tar.gz)
[![License: MIT](https://img.shields.io/badge/License-MIT-slate?style=for-the-badge)](LICENSE)

---

## Why Station?

AI agents and local automations shouldn't fail on Manifest V3 extension limits, burn 48,000 tokens reading raw HTML, or hit login walls:

| Capability | **Station v0.4** | OpenCLI | Agent-Reach | Playwright MCP |
|---|---|---|---|---|
| **Median command latency** | **`0.36 ms` (Rust persistent WS)** | `28–310 ms` | `400 ms–2.5 s` | `120–450 ms` |
| **Browser extension needed** | **None (Native CDP)** | Yes (MV3 bridge) | None | None |
| **Uses your logged-in sessions** | **Yes (Isolated Chrome profiles)** | Yes | No (Public scrapers) | Logged-out / Bot-flagged |
| **Clicks, React forms & file uploads** | **`@eN` refs + chunked `DataTransfer`** | File chooser blocked | Read-only | Verbose HTML |
| **Background tabs (no focus steal)** | **Persistent per-tab socket pool** | Partial | N/A | Headless only |
| **Native MCP with `--auto-start`** | **Single binary (`station mcp`)** | Needs Node daemon | Wrapper scripts | Node `npx` |
| **Auto-Jobs, SQLite CRM & Charts** | **Native Swift 6 macOS Studio** | CLI only | CLI only | None |

---

## 1. Quick Start

### Option A: Download Station Studio for macOS (Self-Contained `.dmg`)
Download **[Station-Studio-v0.4.0-macOS-arm64.dmg](https://github.com/selibrah/station/releases/latest/download/Station-Studio-v0.4.0-macOS-arm64.dmg)**, drag **Station Studio.app** to `/Applications`, and open it. The compiled `station` Rust daemon & MCP server is bundled right inside `Station Studio.app/Contents/MacOS/station` — no Rust toolchain required.

> *First launch note (unsigned open-source build):* If macOS Gatekeeper prompts, right-click `Station Studio.app` → **Open** (or run `xattr -cr "/Applications/Station Studio.app"`).

### Option B: Build from Source (Rust)
```bash
git clone https://github.com/selibrah/station.git
cd station/daemon
cargo build --release
./target/release/station doctor
```

---

## 2. Connect to Claude Code, Cursor, Windsurf & Antigravity (MCP)

Open **Station Studio → MCP Hub (`⌘5`)** for one-click linking, or run:

```bash
claude mcp add station -- /Applications/Station\ Studio.app/Contents/MacOS/station mcp --auto-start
```

Or add to `mcpServers` in `~/.cursor/mcp.json` / `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "station": {
      "command": "/Applications/Station Studio.app/Contents/MacOS/station",
      "args": ["mcp", "--auto-start"]
    }
  }
}
```

With `--auto-start`, AI agents automatically wake the local Station daemon on their first tool call.

### 11 Built-In MCP Tools
- `station_snapshot` — Indexes visible buttons, inputs & links as `@e1..@eN` refs (`~95%` fewer tokens than HTML)
- `station_act` — React/Vue/Angular-safe `click`, `fill`, `select`, `press`, `hover`, and `scroll` via `@eN` refs
- `station_read` — Extracts clean Readability-style Markdown from open or ephemeral background tabs using your cookies
- `station_upload` — Attaches local files (PDF resumes, images, CSVs) via chunked `DataTransfer` without file-chooser popups
- `station_tabs` / `station_navigate` — Background tab creation (`background: true`), pinning, and routing
- `station_screenshot` — Native MCP `image` blocks (`PNG`/`JPEG`) for multimodal visual verification
- `station_eval` / `station_inject` / `station_status` / `station_doctor`

---

## 3. Auto-Jobs, Local SQLite CRM & Native Swift Charts

Station includes flagship autonomous watchers + a unified **Findings & Charts (`⌘2`)** screen inside **Station Studio**:

- **Housing & Rent Watcher (`rent-finder/`):** Polls property portals and logged-in Facebook groups chronologically, scores neighborhood proximity, detects price drops, generates 1-tap WhatsApp links, and syncs two-way with SQLite.
- **Multi-Board Job Hunter (`job-finder/`):** Scans LinkedIn Jobs, Hacker News Jobs, and ATS career boards in background tabs, scores stack fit & salaries, and tracks `Matched → Applied → Interview → Offer`.
- **Custom `url:` Watchers:** Schedule any authenticated URL (`url:https://...`) in `⌘3` Auto-Jobs to harvest structured items into SQLite and visualize **Conversion Funnels**, **14-Day Discovery Velocity**, and **Price / Salary Histograms**.

---

## Repository Structure

| Directory | Description |
|---|---|
| `daemon/` | Rust HTTP/CDP daemon + native stdio MCP server (`src/{main,server,cdp,browser,dom,mcp,gemini}.rs`) |
| `studio-app/` | Native Swift 6 macOS menu bar & desktop app (`StationCore` + `StationStudio` + Swift Charts + SQLite3) |
| `job-finder/` | Multi-board authenticated job & lead watcher (`job_watch.py`) |
| `rent-finder/` | Multi-portal & Facebook group housing watcher + optional web mirror (`rent_watch.py`, `dashboard.py`) |
| `clients/` | Shell (`station.sh`), Python, and Node client helpers |
| `skills/station/` | Ready-to-install agent `SKILL.md` |
| `landing/` | Zero-dependency SEO landing page with live benchmark & `@eN` inspector simulator |

---

## Security & Responsible Use

- **100% Local:** Binds strictly to `127.0.0.1:19826` with CORS disabled and constant-time verified `0600` token headers (`X-Station-Token`).
- **Human-in-the-Loop:** Station never attempts to solve or bypass CAPTCHAs or anti-bot challenges, and pauses before irreversible submissions so you stay in control.

## License

[MIT](LICENSE)
