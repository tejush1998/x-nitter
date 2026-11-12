#!/bin/bash
# Start nitter locally: (re)generate sessions from .env cookies, then launch.
# The cache is SQLite (cache.db); only builds made with -d:redisCache need valkey running.
cd "$(dirname "$0")"
pkill -x nitter >/dev/null 2>&1
sleep 1
node --env-file=.env make_sessions.mjs
nohup ./nitter > /tmp/nitter.log 2>&1 &
echo "nitter started (pid $!)  log: /tmp/nitter.log"
