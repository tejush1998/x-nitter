# x-nitter

A personal fork of [Nitter](https://github.com/zedeus/nitter) that merges the
x-time feed engine into the Nitter server. Nitter's lightweight front-end stays
as-is; x-nitter adds an authenticated "For You"-style feed dashboard on top.

## What this adds over Nitter

- **`/xtime/` dashboard** — a feed UI served at `http://localhost:8080/xtime/`
  on the same server as Nitter.
- **Logged-in timeline scraping** — fetches your For You timeline with your own
  X session through `scraper.py` (uses the
  [twifork](https://pypi.org/project/twifork/) twikit fork with browser
  impersonation), in configurable batches.
- **Local tweet store** — every batch is persisted to a local SQLite database
  (`feed.db`), so browsing is instant and works offline.
- **LLM classification & translation** — tweets are classified into your
  configured topics and optionally translated, via any OpenAI-compatible API
  (provider, model, base URL and API-key env var are set in
  `xtime.config.json`).
- **Interactions** — like/unlike tweets and follow/unfollow accounts directly
  from the UI (POST `/api/like`, `/api/follow`, GET `/api/following`).
- **Scrape API** — trigger scrapes and reclassification from the UI or curl
  (`POST /api/scrape`, `POST /api/reclassify`, `GET /api/snapshot`).
- **CLI** — `src/xtimecli.nim` offers the same scrape/view/reclassify flow from
  the terminal.
- All upstream Nitter features remain: no-JS front-end, RSS, themes,
  lightweight pages.

## Cookies

x-nitter drives your own logged-in X account, so it needs two session cookies:
`auth_token` and `ct0`.

1. Log in to x.com in your browser.
2. Open DevTools → Application (Firefox: Storage) → Cookies → `https://x.com`.
3. Copy the values of `auth_token` and `ct0`.
4. Put them in a `.env` file in the repo root:

   ```
   AUTH_TOKEN=<auth_token value>
   CT0=<ct0 value>
   ```

5. Generate the Nitter session file (used by Nitter's own API requests):

   ```bash
   node --env-file=.env make_sessions.mjs
   ```

   This writes `sessions.jsonl`. Re-run it whenever you refresh the cookies.

- Alternatively, `scraper.py` accepts a `cookies.json` file (either a
  `{name: value}` dict or a DevTools "export cookies" array).
- Cookies expire periodically — if you see "Cookies are expired or invalid",
  re-export both values and regenerate `sessions.jsonl`.
- Treat these cookies like passwords: `.env`, `cookies.json` and
  `sessions.json*` are gitignored and must never be committed.

## xtime configuration

`xtime.config.json` (repo root, gitignored) controls the feed:

- `topics` — the topic list the classifier sorts tweets into
- `providers` + `classify.provider` / `translate.provider` — an
  OpenAI-compatible endpoint: `model`, `baseUrl`, `apiKeyEnv` (name of an env
  var holding the API key, e.g. `OPENAI_API_KEY` set in `.env`), `timeoutMs`
- `translate.enabled` — turn translation on/off
- `pages`, `countPerPage`, `maxTopics`, `minPollIntervalSec`, `linkBase`

## Python helper

The scrape/like/follow backend shells out to `scraper.py`, which needs the
twifork package. Create a virtualenv in the repo root:

```bash
python3 -m venv .venv
.venv/bin/pip install twifork
```

## Running

The easiest way on macOS is the launcher script, which builds the binary if
needed, starts Valkey, regenerates sessions and opens the UI:

```bash
xnitter.sh
```

or manually:

```bash
nim c -d:ssl --threads:off -o:./xnitter src/nitter.nim
./xnitter
```

Nitter listens on the address/port set in `nitter.conf` (default
`127.0.0.1:8080`); the xtime dashboard is at `/xtime/`.

## Installation

### Dependencies

- libpcre
- libsass
- redis/valkey

To compile Nitter you need a Nim installation, see
[nim-lang.org](https://nim-lang.org/install.html) for details. It is possible
to install it system-wide or in the user directory you create below.

To compile the scss files, you need to install `libsass`. On Ubuntu and Debian,
you can use `libsass-dev`.

Redis is required for caching and in the future for account info. As of 2024
Redis is no longer open source, so using the fork Valkey is recommended. It
should be available on most distros as `redis` or `redis-server`
(Ubuntu/Debian), or `valkey`/`valkey-server`. Running it with the default
config is fine, Nitter's default config is set to use the default port and
localhost.

Here's how to create a `nitter` user, clone the repo, and build the project
along with the scss and md files.

```bash
# useradd -m nitter
# su nitter
$ git clone https://github.com/zedeus/nitter
$ cd nitter
$ nimble -l build -d:danger --mm:refc
$ nimble -l scss
$ nimble -l md
$ cp nitter.example.conf nitter.conf
```

Set your hostname, port, HMAC key, https (must be correct for cookies), and
Redis info in `nitter.conf`. To run Redis, either run
`redis-server --daemonize yes`, or `systemctl enable --now redis` (or
redis-server depending on the distro). Run Nitter by executing `./nitter` or
using the systemd service below. You should run Nitter behind a reverse proxy
such as [Nginx](https://github.com/zedeus/nitter/wiki/Nginx) or
[Apache](https://github.com/zedeus/nitter/wiki/Apache) for security and
performance reasons.

### Docker

Page for the Docker image: https://hub.docker.com/r/zedeus/nitter

#### NOTE: The published image is multi-arch — `zedeus/nitter:latest` runs natively on both `amd64` and `arm64`.

To run Nitter with Docker, you'll need to install and run Redis separately
before you can run the container. See below for how to also run Redis using
Docker.

First create your config file. The Docker commands mount it into the container,
so it has to exist on the host beforehand. If you've cloned the repo:

```bash
cp nitter.example.conf nitter.conf
```

If you're using the prebuilt image without a local clone, download
[`nitter.example.conf`](https://raw.githubusercontent.com/zedeus/nitter/master/nitter.example.conf)
and save it as `nitter.conf` instead.

To build and run Nitter in Docker:

```bash
docker build -t nitter:latest .
docker run -v $(pwd)/nitter.conf:/src/nitter.conf -d --network host nitter:latest
```

A prebuilt Docker image is provided as well:

```bash
docker run -v $(pwd)/nitter.conf:/src/nitter.conf -d --network host zedeus/nitter:latest
```

Using docker-compose to run both Nitter and Redis as different containers:
Change `redisHost` from `localhost` to `nitter-redis` in `nitter.conf`, then run:

```bash
docker-compose up -d
```

Note the Docker commands mount `nitter.conf` (and `sessions.jsonl` for
docker-compose) from the directory you run them in. If a mounted file doesn't
exist, Docker silently creates a directory in its place and the container fails
with `not a directory: Are you trying to mount a directory onto a file`. Remove
that directory and create the file as shown above.

### systemd

To run Nitter via systemd you can use this service file:

```ini
[Unit]
Description=Nitter (An alternative Twitter front-end)
After=syslog.target
After=network.target

[Service]
Type=simple

# set user and group
User=nitter
Group=nitter

# configure location
WorkingDirectory=/home/nitter/nitter
ExecStart=/home/nitter/nitter/nitter

Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
```

Then enable and run the service:
`systemctl enable --now nitter.service`

### Logging

Nitter currently prints some errors to stdout, and there is no real logging
implemented. If you're running Nitter with systemd, you can check stdout like
this: `journalctl -u nitter.service` (add `--follow` to see just the last 15
lines). If you're running the Docker image, you can do this:
`docker logs --follow *nitter container id*`

## Contact

Feel free to join our [Matrix channel](https://matrix.to/#/#nitter:matrix.org).
You can email me at zedeus@pm.me if you wish to contact me personally.

For legal inquiries, contact legal@poast.org
