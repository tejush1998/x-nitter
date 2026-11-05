#!/bin/bash
# Start nitter locally: ensure valkey is up, (re)generate sessions from .env cookies, then launch.
cd "$(dirname "$0")"
brew services start valkey >/dev/null 2>&1
pkill -x nitter >/dev/null 2>&1
sleep 1
node --env-file=.env make_sessions.mjs
nohup ./nitter > /tmp/nitter.log 2>&1 &
echo "nitter started (pid $!)  log: /tmp/nitter.log"
