#!/bin/bash
# Start x-nitter by hand: regenerate sessions from .env cookies, build ./xnitter if it's missing, then launch.
# Day to day the Alfred keyword `xnitter` (on | off | status) does the same, minus the sessions step.
# The cache is SQLite (cache.db); only builds made with -d:redisCache need valkey running.
cd "$(dirname "$0")"
PORT=8080 # must match nitter.conf
LOG=/tmp/xnitter.log
pkill -x xnitter >/dev/null 2>&1
sleep 1
# x-nitter binds with reusePort, so a second server would silently share the port
pid=$(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN | head -n 1)
if [ -n "$pid" ]; then
  echo "Port $PORT is taken by $(ps -o comm= -p "$pid")"
  exit 1
fi
node --env-file=.env make_sessions.mjs
if [ ! -x ./xnitter ] && ! nim c -d:ssl --threads:off -o:./xnitter src/nitter.nim > "$LOG" 2>&1; then
  echo "Build failed, see $LOG"
  exit 1
fi
nohup ./xnitter > "$LOG" 2>&1 < /dev/null &
echo "x-nitter started (pid $!)  log: $LOG"
