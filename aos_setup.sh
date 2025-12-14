#!/bin/sh

set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$REPO_DIR/logs"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

mkdir -p "$LOG_DIR"
cd "$REPO_DIR" || exit 1

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

log "Setup complete."
exit 0
