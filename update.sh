#!/bin/bash
# Update x-nitter: pull this fork (origin, tejush1998/x-nitter), rebuild ./xnitter,
# regenerate css/md, and restart.
set -e
cd "$(dirname "$0")"
LOG=/tmp/xnitter.log
git pull --ff-only
# build next to the running binary, then swap it in, so the running server's file isn't rewritten under it
nim c -d:ssl --threads:off -o:./xnitter.new src/nitter.nim
nim c -o:/tmp/gencss tools/gencss
DYLD_LIBRARY_PATH=/opt/homebrew/opt/libsass/lib /tmp/gencss
nimble -l md
mv ./xnitter.new ./xnitter
pkill -x xnitter 2>/dev/null || true
sleep 1
nohup ./xnitter > "$LOG" 2>&1 < /dev/null &
echo "x-nitter restarted (pid $!)  log: $LOG"
