#!/bin/bash

# xnitter.sh — launcher for the merged x-nitter server (nitter fork + x-time in one)
# Starts the xnitter binary on :8080 and opens the x-time feed UI.
# Env overrides:
#   XNITTER_REPO_DIR   repo location (default /Users/mac/Documents/web-apps/x-nitter)
#   XNITTER_REBUILD=1  force rebuild before start
#   XNITTER_PORT       port to open in browser (default 8080; must match nitter.conf)

get_script_dir() {
  local path="${BASH_SOURCE[0]}"
  while [[ -L "$path" ]]; do
    local dir
    dir="$(cd "$(dirname "$path")" && pwd)"
    path="$(readlink "$path")"
    [[ "$path" != /* ]] && path="$dir/$path"
  done
  cd "$(dirname "$path")" && pwd -P
}

SCRIPT_DIR="$(get_script_dir)"

REPO_DIR="${XNITTER_REPO_DIR:-/Users/mac/Documents/web-apps/x-nitter}"
if [[ -f "$SCRIPT_DIR/nitter.nimble" ]]; then
  REPO_DIR="$SCRIPT_DIR"
fi

cd "$REPO_DIR" || exit 1

PORT="${XNITTER_PORT:-8080}"
BIN="./xnitter"
LOG="/tmp/xnitter.log"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    echo "xnitter stopped"
  fi
  exit 0
}

trap cleanup SIGINT

if ! command -v nim >/dev/null 2>&1; then
  echo "error: nim not found in PATH" >&2
  exit 1
fi

# build if missing or forced
if [[ ! -f "$BIN" || "${XNITTER_REBUILD:-0}" == "1" ]]; then
  echo "building xnitter..."
  nim c -d:ssl --threads:off -o:"$BIN" src/nitter.nim || exit 1
fi

# redis check (required by nitter cache)
if ! redis-cli ping >/dev/null 2>&1; then
  echo "WARNING: redis is not running on :6379 — server will fail to start." >&2
  echo "         start it (e.g. 'redis-server' or docker compose up -d redis) and retry." >&2
  exit 1
fi

# abort if :8080 is already taken (nitter uses reusePort, so two servers
# would silently share the port and round-robin requests)
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | tail -n +2 | grep -q .; then
  echo "error: port $PORT already in use:" >&2
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN | tail -n +2 >&2
  echo "       kill the stale process first (avoid reusePort round-robin)." >&2
  exit 1
fi

# also stop any stray xnitter instance from a previous run
pkill -x xnitter 2>/dev/null

"$BIN" > "$LOG" 2>&1 &
SERVER_PID=$!

sleep 2
open "http://localhost:${PORT}/xtime/"

echo "xnitter running (pid $SERVER_PID, log $LOG) — http://localhost:${PORT}/xtime/"
wait "$SERVER_PID"
