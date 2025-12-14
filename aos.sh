#!/bin/sh

set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$REPO_DIR/logs"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

mkdir -p "$LOG_DIR"
cd "$REPO_DIR" || exit 1

log "Starting GPIO listener..."
python3 "$REPO_DIR/button.py" > "$LOG_DIR/button.log" 2>&1 &

log "Starting Node server..."
npm start --prefix "$REPO_DIR" > "$LOG_DIR/aosjs.log" 2>&1 &

sleep 10s

log "Launching Chromium kiosk..."
chromium --kiosk "http://localhost:4173" --password-store=basic > "$LOG_DIR/chromium.log" 2>&1 &

exit 0
