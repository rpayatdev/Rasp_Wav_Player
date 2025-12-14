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

# Warten bis der HTTP-Server bereit ist, bevor Chromium gestartet wird
wait_for_http() {
  local url="$1"
  local retries="${2:-30}"
  local delay="${3:-2}"

  for _ in $(seq 1 "$retries"); do
    if command -v curl >/dev/null 2>&1; then
      if curl -fs "$url" >/dev/null 2>&1; then
        return 0
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -qO- "$url" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep "$delay"
  done
  return 1
}

if wait_for_http "http://localhost:4173"; then
  log "Node server reachable, launching Chromium..."
else
  log "Node server not reachable after waiting. Launching Chromium anyway."
fi

log "Launching Chromium kiosk..."
chromium \
  --kiosk "http://localhost:4173" \
  --password-store=basic \
  --lang=de-DE \
  --enable-logging=stderr \
  --v=0 \
  > "$LOG_DIR/chromium.log" 2>&1 &

exit 0
