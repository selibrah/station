#!/usr/bin/env bash
# Thin CLI client for station (Rust CDP & MCP daemon, port 19826).
# Usage:
#   ./station.sh up [profile] [url]         # build+start daemon (default profile: "default")
#   ./station.sh doctor                     # run station health diagnostics
#   ./station.sh tabs                       # list open browser tabs
#   ./station.sh open <url> [bg]            # open a URL in a new tab (pass "bg" for background)
#   ./station.sh close <target_id>          # close a tab by target_id
#   ./station.sh snapshot [session]         # dump @e1..@eN interactive DOM map
#   ./station.sh read [url_or_session]      # extract clean Markdown from a tab or URL
#   ./station.sh act <action> [ref] [val]   # click/fill/press/select/scroll (e.g. act click @e3)
#   ./station.sh screenshot [out.png]       # save PNG screenshot of active tab
#   ./station.sh js <host> '<js>'           # run JS in the tab matching <host>
#   ./station.sh links <host> '<selector>'  # dump {text,href} of matching anchors as JSON
#   ./station.sh scroll <host> [n]          # scroll to bottom n times (lazy-load more results)
set -euo pipefail
PORT=${STATION_PORT:-19826}
STATION_DIR="${STATION_DIR:-$(cd "$(dirname "$0")/../../daemon" && pwd)}"
STATION_BIN="$STATION_DIR/target/release/station"
tok() { cat "${STATION_TOKEN_FILE:-$HOME/.flossi/station.token}"; }
get()  { curl -sf "http://127.0.0.1:$PORT/$1" -H "X-Station-Token: $(tok)"; }
post() { curl -sf -X POST "http://127.0.0.1:$PORT/$1" -H "X-Station-Token: $(tok)" -H 'Content-Type: application/json' -d "$2"; }
jq_or_cat() { command -v jq >/dev/null && jq . || cat; }

case "${1:-}" in
  up)
    (cd "$STATION_DIR" && cargo build --release --quiet)
    exec "$STATION_BIN" --standard-window --profile-name "${2:-default}" --url "${3:-about:blank}" --force ;;
  doctor)
    exec "$STATION_BIN" --port "$PORT" doctor ;;
  tabs)
    get tabs | jq_or_cat ;;
  open)
    BG=$([[ "${3:-}" == "bg" ]] && echo true || echo false)
    post tabs/new "$(python3 -c 'import json,sys;print(json.dumps({"url":sys.argv[1],"background":sys.argv[2]=="true"}))' "$2" "$BG")" | jq_or_cat ;;
  close)
    post tabs/close "$(python3 -c 'import json,sys;print(json.dumps({"target_id":sys.argv[1]}))' "$2")" | jq_or_cat ;;
  snapshot)
    exec "$STATION_BIN" --port "$PORT" snapshot ${2:+--session "$2"} ;;
  read)
    if [[ "${2:-}" =~ ^https?:// ]]; then
      exec "$STATION_BIN" --port "$PORT" read "$2"
    else
      exec "$STATION_BIN" --port "$PORT" read ${2:+--session "$2"}
    fi ;;
  act)
    exec "$STATION_BIN" --port "$PORT" act "$2" ${3:+"$3"} ${4:+"$4"} ;;
  screenshot)
    exec "$STATION_BIN" --port "$PORT" --screenshot "${2:-screenshot.png}" ;;
  js)
    post command "$(python3 -c 'import json,sys;print(json.dumps({"session":sys.argv[1],"code":sys.argv[2],"timeout":30000}))' "$2" "$3")" | jq_or_cat ;;
  links)
    "$0" js "$2" "JSON.stringify([...document.querySelectorAll('$3')].map(a=>({text:a.innerText.trim().slice(0,120),href:a.href})).filter(x=>x.href))" ;;
  scroll)
    for _ in $(seq "${3:-3}"); do "$0" js "$2" 'window.scrollTo(0,document.body.scrollHeight);"ok"' >/dev/null; sleep 1.5; done; echo scrolled ;;
  *) sed -n '2,15p' "$0" ;;
esac
