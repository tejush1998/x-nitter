#!/bin/bash
# Start nitter locally: ensure valkey is up, (re)generate sessions from x-time's .env cookies, then launch.
cd "$(dirname "$0")"
brew services start valkey >/dev/null 2>&1
pkill -x nitter >/dev/null 2>&1
sleep 1
node --env-file=/Users/mac/Documents/web-apps/x-time/.env make_sessions.mjs
nohup ./nitter > /tmp/nitter.log 2>&1 &
echo "nitter started (pid $!)  log: /tmp/nitter.log"
