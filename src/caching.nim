# SPDX-License-Identifier: AGPL-3.0-only
# Cache backend: SQLite by default (no server to run); build with -d:redisCache to use
# upstream's Redis/Valkey cache instead. Both expose the same getCached*/cache procs.
import strformat
import types

when defined(redisCache):
  import asyncdispatch, redis_cache
  export redis_cache

  proc initCache*(cfg: Config) =
    waitFor initRedisPool(cfg)
    stdout.write &"Connected to Redis at {cfg.redisHost}:{cfg.redisPort}\n"
else:
  import sqlite_cache
  export sqlite_cache

  proc initCache*(cfg: Config) =
    initSqliteCache(cfg)
    stdout.write &"Cache: SQLite at {cfg.cachePath}\n"
