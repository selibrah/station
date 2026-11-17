---
name: station
description: Drive a real authenticated Chrome browser at sub-millisecond CDP speed (0.36ms) with zero browser extensions. Use for reading logged-in pages as clean Markdown, inspecting @e1..@eN interactive DOM snapshots, clicking/filling React/Vue/Angular forms, uploading files without user-gesture blocks, and running job/rent search workflows via MCP or CLI.
---

# Station — Authenticated Sub-ms Browser & MCP Engine

Station (`station`) is a single native Rust binary that connects directly to Chrome over persistent DevTools Protocol WebSockets (`127.0.0.1:19826`) using isolated, logged-in profiles (`~/.flossi/profiles/<name>`). No Chrome extension or paid scraping API is required.

## 1. Connect via MCP (Recommended)

Add Station to Claude Code, Claude Desktop, Cursor, Windsurf, or Antigravity:

```bash
claude mcp add station -- /path/to/station mcp --auto-start
```

Or in `mcpServers` JSON:

```json
{
  "mcpServers": {
    "station": {
      "command": "/path/to/station",
      "args": ["mcp", "--auto-start"]
    }
  }
}
```

With `--auto-start`, the MCP server automatically launches the Station daemon in the background on the first tool call if it is not already running.

### Core MCP Tool Workflow
1. **`station_tabs`** (`action: "list"` or `"open"` with `background: true`) — open or locate tabs without stealing focus from the user's window.
2. **`station_read`** — extract clean Markdown (`~90%` fewer tokens than HTML) from an open tab or pass `url` to read any page in an ephemeral background tab using the user's cookies.
3. **`station_snapshot`** — index visible interactive buttons, inputs, and links as `@e1..@eN` references.
4. **`station_act`** — `click`, `fill`, `select`, `press`, `hover`, or `scroll` targeting `@eN` refs or CSS selectors.
5. **`station_upload`** — attach local files (PDF resumes, images, CSVs) via chunked `DataTransfer` without triggering OS file dialogs.
6. **`station_screenshot`** — capture native MCP image blocks (`PNG`/`JPEG`) for visual verification.

## 2. Direct CLI Primitives

```bash
station doctor                           # Verify Chrome, CDP latency, token & MCP readiness
station snapshot --session linkedin      # Print @e1..@eN interactive element map
station act fill @e2 "Rust Engineer"     # Fill React/Angular input cleanly
station act press @e2 Enter              # Submit search
station read https://news.ycombinator.com # Ephemeral background tab -> clean Markdown
```

## Safety Guardrails
- Never attempt to solve or bypass CAPTCHAs or anti-bot challenges; pause and ask the user to complete verification in the browser window.
- Pause before clicking final irreversible Submit / Purchase / Apply buttons and confirm with the user.
