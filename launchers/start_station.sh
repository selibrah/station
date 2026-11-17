#!/usr/bin/env bash
# start_station.sh — build (only when the source changed) and start the station daemon.
# Extra arguments go to the daemon, e.g. ./start_station.sh --url https://x.com --profile-name social

set -euo pipefail

DAEMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../daemon" && pwd)"
(cd "${DAEMON_DIR}" && cargo build --release --quiet)

# --force only replaces an older station; it never touches OpenCLI's daemon on 19825
echo "🚀 Starting station on port 19826..."
exec "${DAEMON_DIR}/target/release/station" --force "$@"
