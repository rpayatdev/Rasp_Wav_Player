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
if command -v git >/dev/null 2>&1; then
  if ! git -C "$REPO_DIR" pull --rebase --autostash; then
    log "Git pull skipped/failed (offline or local changes). Continuing with current files."
  fi
else
  log "Git not found; skipping auto-update."
fi

if command -v npm >/dev/null 2>&1; then
  log "Installing server/UI dependencies..."
  if ! npm install --prefix "$REPO_DIR"; then
    log "npm install failed; continuing with existing node_modules."
  fi

  log "Building web UI..."
  if ! npm run build --prefix "$REPO_DIR"; then
    log "Build failed; continuing with existing dist (if present)."
  fi
else
  if [ -d "$DIST_DIR" ]; then
    log "npm not found; skipping install/build (existing dist will be used)."
  else
    log "npm not found and dist missing; cannot build UI. Install Node or copy dist."
  fi
fi

if command -v python3 >/dev/null 2>&1; then
  log "Starting GPIO listener..."
  python3 "$REPO_DIR/button.py" > "$LOG_DIR/button.log" 2>&1 &
else
  log "python3 not found; GPIO listener not started."
fi

if command -v npm >/dev/null 2>&1; then
  log "Starting Node server..."
  npm start --prefix "$REPO_DIR" > "$LOG_DIR/aosjs.log" 2>&1 &
else
  log "npm not found; Node server not started."
fi

sleep 10s

if command -v chromium >/dev/null 2>&1; then
  log "Launching Chromium kiosk..."
  chromium --kiosk "http://localhost:4173" --password-store=basic \
    > "$LOG_DIR/chromium.log" 2>&1 &
else
  log "chromium not found; skipping kiosk launch."
fi

exit 0
