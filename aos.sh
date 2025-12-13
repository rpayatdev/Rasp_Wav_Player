#!/bin/sh

set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$REPO_DIR/logs"
DIST_DIR="$REPO_DIR/rasp_wav_player/dist"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

mkdir -p "$LOG_DIR"
cd "$REPO_DIR"

log "Updating repository (git pull --rebase)..."

if ! git -C "$REPO_DIR" pull --rebase --autostash; then
  log "Git pull skipped/failed (offline or local changes). Continuing with current files."
fi


log "Installing server/UI dependencies..."
if ! npm install --prefix "$REPO_DIR"; then
  log "npm install failed; continuing with existing node_modules."
fi

log "Building web UI..."
if ! npm run build --prefix "$REPO_DIR"; then
  log "Build failed; continuing with existing dist (if present)."
fi

log "Starting GPIO listener..."
python3 "$REPO_DIR/button.py" > "$LOG_DIR/button.log" 2>&1 &


log "Starting Node server..."
npm start --prefix "$REPO_DIR" > "$LOG_DIR/aosjs.log" 2>&1 &

sleep 10s

log "Launching Chromium kiosk..."
chromium --kiosk "http://localhost:4173" --password-store=basic \ > "$LOG_DIR/chromium.log" 2>&1 &


exit 0
