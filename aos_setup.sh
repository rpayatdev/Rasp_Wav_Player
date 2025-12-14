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
HEAD_BEFORE="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
if ! git -C "$REPO_DIR" pull --rebase --autostash; then
  log "Git pull failed or skipped (offline or local changes). No further steps executed."
  exit 0
fi
HEAD_AFTER="$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"

if [ "$HEAD_BEFORE" = "$HEAD_AFTER" ]; then
  log "Repository already up to date. Skipping install/build."
  exit 0
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
