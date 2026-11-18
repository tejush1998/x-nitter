FROM nimlang/nim:2.2.10 AS nim

RUN apt-get update \
    && apt-get install -y --no-install-recommends libsass-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src/nitter

COPY nitter.nimble .
RUN nimble install -y --depsOnly

COPY . .
RUN nimble build -d:release -d:strip \
    && nimble scss \
    && nimble md

# Same Debian release as the build stage, so the binary finds the glibc it was linked against
FROM python:3.13-slim-bookworm
LABEL org.opencontainers.image.source="https://github.com/tejush1998/x-nitter"

RUN apt-get update \
    && apt-get install -y --no-install-recommends libpcre3 \
    && rm -rf /var/lib/apt/lists/*
# scraper.py's X client; curl_cffi gives it a browser TLS fingerprint
RUN pip install --no-cache-dir twifork==2.3.5 curl_cffi==0.7.4

WORKDIR /app
COPY --from=nim /src/nitter/nitter ./xnitter
COPY --from=nim /src/nitter/xtimecli ./
COPY --from=nim /src/nitter/public ./public
COPY scraper.py nitter.example.conf xtime.config.example.json docker-entrypoint.sh ./

# Everything that changes at runtime lives in /data
ENV NITTER_CONF_FILE=/data/nitter.conf \
    NITTER_SESSIONS_FILE=/data/sessions.jsonl \
    XTIME_CONF_FILE=/data/xtime.config.json \
    XTIME_DB_FILE=/data/feed.db
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=2 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/xtime/')"
ENTRYPOINT ["./docker-entrypoint.sh"]
