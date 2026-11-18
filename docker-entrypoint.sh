#!/bin/sh
# Container start: drop to PUID:PGID, put default configs in /data on the first run,
# write the X session from AUTH_TOKEN/CT0 (what make_sessions.mjs does outside Docker), then start.
set -e

if [ "$(id -u)" = 0 ]; then
  chown -R "${PUID:-1000}:${PGID:-1000}" /data
  exec setpriv --reuid="${PUID:-1000}" --regid="${PGID:-1000}" --clear-groups "$0" "$@"
fi

if [ ! -f "$NITTER_CONF_FILE" ]; then
  key=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
  sed -e 's|^hostname = "[^"]*"|hostname = "localhost:8080"|' \
      -e 's|^sqlitePath = "[^"]*"|sqlitePath = "/data/cache.db"|' \
      -e "s|^hmacKey = .*|hmacKey = \"$key\"|" \
      nitter.example.conf > "$NITTER_CONF_FILE"
  echo "Wrote $NITTER_CONF_FILE"
fi
if [ ! -f "$XTIME_CONF_FILE" ]; then
  cp xtime.config.example.json "$XTIME_CONF_FILE"
  echo "Wrote $XTIME_CONF_FILE"
fi

# Rewritten on every start, so new cookies in .env only need a container restart
if [ -n "$AUTH_TOKEN" ] && [ -n "$CT0" ]; then
  python3 -c 'import json, os; print(json.dumps({"kind": "cookie", "auth_token": os.environ["AUTH_TOKEN"], "ct0": os.environ["CT0"], "username": "local", "id": "1"}))' \
    > "$NITTER_SESSIONS_FILE"
elif [ ! -f "$NITTER_SESSIONS_FILE" ]; then
  echo "Set AUTH_TOKEN and CT0 in .env (see .env.example), then recreate the container" >&2
  exit 1
fi

exec ./xnitter "$@"
