#!/bin/bash
# Update nitter: pull latest from the git remote (currently the archived
# zedeus/nitter original), rebuild, regenerate css/md, and restart.
set -e
cd "$(dirname "$0")"
git pull --ff-only
nimble -l build -d:danger --mm:refc
nim c -o:/tmp/gencss tools/gencss
DYLD_LIBRARY_PATH=/opt/homebrew/opt/libsass/lib /tmp/gencss
nimble -l md
pkill -x nitter 2>/dev/null || true
sleep 1
nohup ./nitter > /tmp/nitter.log 2>&1 &
echo "nitter restarted (pid $!)  log: /tmp/nitter.log"
