# Nitter — Local Setup (Layman's Guide)

This doc explains how this local nitter instance works and how to run it,
in plain English. For what nitter itself is, see `README.md`.

## What is nitter?

Nitter is an alternative frontend for X/Twitter. It lets you view tweets and
user pages without logging into X and without X's ads/tracking — think of it
as a privacy-friendly "reader" for Twitter content. It runs as a small web
server on your own machine and pulls the actual tweets from X behind the
scenes.

## Where is the program?

Nitter is written in the Nim language and compiled to a single native binary:

```
/Users/mac/Documents/web-apps/nitter/nitter   (~3.7 MB)
```

It's the whole app in one file. No Docker, no VM, no interpreter needed at
runtime — that's why it's so light (compare: Docker Desktop's VM alone eats
~2 GB of RAM).

## How does it run?

When you start nitter, it:

1. Reads its settings from `nitter.conf` in this folder
   (listens on `http://localhost:8080`).
2. Loads your X account "session" from `sessions.jsonl` so it can fetch
   tweets *as you* (see below).
3. Uses a small cache server (Valkey) so it doesn't hammer X for the same
   tweet twice.
4. Starts a background web server that answers requests on port 8080.

It keeps running in the background even after you close the terminal — that's
what `nohup` is for (explained below).

## What is Valkey? Am I running Redis?

**Valkey** is the modern open-source successor to **Redis**. Redis was
renamed/forked into Valkey when Redis Ltd. changed its licensing. Valkey is a
drop-in replacement: same commands, same protocol, same default port (6379).

You are **not** running "Redis" — you're running **Valkey** (`valkey-server`,
installed via Homebrew and started as a brew service). Nitter requires a
Redis-compatible cache and happily talks to Valkey on `localhost:6379`.
`redis-cli ping` still works because Valkey speaks the same protocol.

## What does "regenerate sessions.jsonl" mean?

`sessions.jsonl` is a small file containing your X login cookies
(`auth_token` and `ct0`). Nitter uses these cookies to fetch tweets from X as
your logged-in account (without them, X blocks most content).

"Regenerating" it just means: each time you run `start.sh`, a tiny script
(`make_sessions.mjs`) reads `AUTH_TOKEN` and `CT0` from x-time's `.env` file
and rewrites `sessions.jsonl` with your latest cookies. So every restart picks
up your current cookies automatically — you never have to touch this file by
hand. (The cookie values are never printed to the terminal.)

## What is nohup?

`nohup` is a command that says: "run this program and keep it alive even if
the terminal that launched it closes." Combined with `&`, it runs in the
background:

```
nohup ./nitter > /tmp/nitter.log 2>&1 &
```

That means: start nitter in the background, write everything it prints to
`/tmp/nitter.log`, and don't kill it when this shell exits. That's why you can
close the terminal and nitter keeps serving on port 8080.

## How do I start / stop / update it?

All commands must be run from this folder
(`/Users/mac/Documents/web-apps/nitter`), because nitter reads
`nitter.conf` and `sessions.jsonl` from its current working directory.

- **Start:** `bash start.sh`
  - Ensures Valkey is running (`brew services start valkey`)
  - Kills any old nitter instance (`pkill -x nitter`)
  - Regenerates `sessions.jsonl` from x-time's `.env`
  - Launches nitter in the background; logs → `/tmp/nitter.log`

- **Stop:** `pkill -x nitter` (or let start.sh do it on the next run)

- **Update:** `bash update.sh`
  - `git pull` the latest source
  - Rebuild the binary (`nimble -l build -d:danger --mm:refc`)
  - Rebuild CSS and docs
  - Restart the server

## Quick check it's working

- `curl http://localhost:8080/` → returns the nitter homepage
- `curl http://localhost:8080/<username>` → a real user page (fetched via
  your cookies)
- `tail /tmp/nitter.log` → should show "Connected to Redis/Valkey" and
  "successfully added 1 valid account sessions"

## The Follow button on profile pages

This fork adds a small round **+** button on every user page, right next to
the username (same look as the like buttons in x-time). Nitter itself is
read-only — it can't follow anyone — so the button delegates to the
**x-time** server, which owns your X login cookies:

1. When a profile page loads, the button shows dimmed `…` while
   `public/js/follow.js` quietly asks x-time (`http://localhost:4310`)
   whether you already follow that user.
2. The `+` shows in the accent color if you already follow them (hover says
   "Following — click to unfollow"), otherwise it stays grey ("Follow").
3. Clicking it asks x-time to follow (or unfollow) via your X session, then
   flips the state. While waiting it shows `…`; on failure a red `×` with a
   "click to retry" tooltip.

This only works while the x-time server is running (`npm run start` in the
x-time folder; it listens on port 4310). If x-time is down the button still
renders, but the initial check fails silently and clicks show the retry
state. x-time allow-lists `http://localhost:8080` (CORS), so the button only
talks to it from this local nitter.

Files involved, if you want to tweak it:

| File | What it does | Needs rebuild? |
| --- | --- | --- |
| `src/views/profile.nim` | renders the button next to the username | yes (binary) |
| `src/views/general.nim` | loads `/js/follow.js` on every page | yes (binary) |
| `public/js/follow.js` | all the click/state logic | no — bump the `?v=` in general.nim to bust browser cache |
| `src/sass/profile/card.scss` | button styles | yes (CSS regen) |

After Nim/Sass changes, rebuild and restart (`bash update.sh` does all of it,
including a `git pull` you may want to skip if you have uncommitted changes):

```
nimble -l build -d:danger --mm:refc
nim c -o:/tmp/gencss tools/gencss
DYLD_LIBRARY_PATH=/opt/homebrew/opt/libsass/lib /tmp/gencss
pkill -x nitter; nohup ./nitter > /tmp/nitter.log 2>&1 &
```

The x-time side of this feature (its `/api/follow` and `/api/following`
endpoints) is documented in x-time's `README.md`.

## Related: x-time

This nitter instance is used by the **x-time** web app
(`/Users/mac/Documents/web-apps/x-time`). x-time's config (`config.json`) sets
`linkBase` to `http://localhost:8080`, so tweet links in x-time open on your
local nitter instead of x.com.
