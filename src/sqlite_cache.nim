# SPDX-License-Identifier: AGPL-3.0-only
# SQLite cache: same API, keys and TTLs as redis_cache.nim, so nitter runs without a
# Redis/Valkey server. Keep in sync with redis_cache.nim when upstream adds cached types.
import asyncdispatch, times, strutils
import flatty, supersnappy

import types, api
import xtime/vendor/db_sqlite

const
  baseCacheTime = 60 * 60
  purgeEvery = 500  # writes between sweeps of expired rows

var
  db: DbConn
  rssCacheTime: int
  listCacheTime*: int
  writes: int

# flatty can't serialize DateTime, so we need to define this
proc toFlatty*(s: var string, x: DateTime) =
  s.toFlatty(x.toTime().toUnix())

proc fromFlatty*(s: string, i: var int, x: var DateTime) =
  var unix: int64
  s.fromFlatty(i, unix)
  x = fromUnix(unix).utc()

proc setCacheTimes*(cfg: Config) =
  rssCacheTime = cfg.rssCacheTime * 60
  listCacheTime = cfg.listCacheTime * 60

proc purgeExpired() =
  db.exec(sql"DELETE FROM cache WHERE expires > 0 AND expires <= ?", getTime().toUnix)

proc initSqliteCache*(cfg: Config) =
  db = open(connection = cfg.cachePath, user = "", password = "", database = "")
  db.exec(sql"PRAGMA journal_mode=WAL")
  db.exec(sql"PRAGMA synchronous=NORMAL")
  db.exec(sql"PRAGMA busy_timeout=5000")
  db.exec(sql"""CREATE TABLE IF NOT EXISTS cache (
    key TEXT PRIMARY KEY,
    value BLOB NOT NULL,
    expires INTEGER NOT NULL
  )""")
  purgeExpired()

template uidKey(name: string): string = "pid:" & name
template userKey(name: string): string = "p:" & name
template listKey(l: List): string = "l:" & l.id
template tweetKey(id: int64): string = "t:" & $id

proc get(key: string): Future[string] {.async.} =
  ## "" when the key is missing or expired (redis_cache returns redisNil for this)
  result = db.getValue(sql"SELECT value FROM cache WHERE key = ? AND (expires = 0 OR expires > ?)",
                       key, getTime().toUnix)

proc setEx(key: string; time: int; data: string) {.async.} =
  ## time <= 0 stores the key without expiry
  let expires = if time > 0: getTime().toUnix + time else: 0
  # Values are compressed binary, so they're bound as a blob rather than formatted into the SQL.
  let ps = db.prepare("INSERT OR REPLACE INTO cache (key, value, expires) VALUES (?, ?, ?)")
  ps.bindParam(1, key)
  if data.len > 0: ps.bindParam(2, data.toOpenArrayByte(0, data.high))
  else: ps.bindParam(2, "")
  ps.bindParam(3, expires)
  if not db.tryExec(ps): dbError(db)
  ps.finalize()
  inc writes
  if writes mod purgeEvery == 0:
    purgeExpired()

proc cacheUserId(username, id: string) {.async.} =
  if username.len == 0 or id.len == 0: return
  await setEx(toLower(username).uidKey, 0, id)

proc cache*(data: List) {.async.} =
  await setEx(data.listKey, listCacheTime, compress(toFlatty(data)))

proc cache*(data: PhotoRail; name: string) {.async.} =
  await setEx("pr2:" & toLower(name), baseCacheTime * 2, compress(toFlatty(data)))

proc cache*(data: User) {.async.} =
  if data.username.len == 0: return
  let name = toLower(data.username)
  await cacheUserId(name, data.id)
  await setEx(name.userKey, baseCacheTime, compress(toFlatty(data)))

proc cache*(data: Tweet) {.async.} =
  if data.isNil or data.id == 0: return
  await setEx(data.id.tweetKey, baseCacheTime, compress(toFlatty(data)))

proc cacheRss*(query: string; rss: Rss) {.async.} =
  let key = "rss:" & query
  await setEx(key & ":min", rssCacheTime, rss.cursor)
  if rss.cursor != "suspended":
    await setEx(key & ":rss", rssCacheTime, compress(rss.feed))

template deserialize(data, T) =
  try:
    result = fromFlatty(uncompress(data), T)
  except:
    echo "Decompression failed($#): '$#'" % [astToStr(T), data]

proc getUserId*(username: string): Future[string] {.async.} =
  let name = toLower(username)
  result = await get(name.uidKey)
  if result.len == 0:
    let user = await getGraphUser(username)
    if user.suspended:
      return "suspended"
    else:
      await all(cacheUserId(name, user.id), cache(user))
      return user.id

proc getCachedUser*(username: string; fetch=true): Future[User] {.async.} =
  let prof = await get("p:" & toLower(username))
  if prof.len > 0:
    prof.deserialize(User)
  elif fetch:
    result = await getGraphUser(username)
    await cache(result)

proc getCachedUsername*(userId: string): Future[string] {.async.} =
  let
    key = "i:" & userId
    username = await get(key)

  if username.len > 0:
    result = username
  else:
    let user = await getGraphUserById(userId)
    result = user.username
    if result.len > 0:
      await setEx(key, baseCacheTime, result)
      if user.id.len > 0:
        await all(cacheUserId(result, user.id), cache(user))

proc cache*(data: Broadcast) {.async.} =
  if data.id.len == 0: return
  await setEx("bc:" & data.id, baseCacheTime, compress(toFlatty(data)))

proc getCachedBroadcast*(id: string): Future[Broadcast] {.async.} =
  if id.len == 0: return
  let cached = await get("bc:" & id)
  if cached.len > 0:
    cached.deserialize(Broadcast)
  else:
    result = await getBroadcastInfo(id)
    await cache(result)
  result.m3u8Url = await fetchBroadcastStream(result.mediaKey)

proc cache*(data: AudioSpace) {.async.} =
  if data.id.len == 0: return
  let ttl = if data.state == "RUNNING": baseCacheTime div 6 else: baseCacheTime
  await setEx("sp:" & data.id, ttl, compress(toFlatty(data)))

proc getCachedAudioSpace*(id: string): Future[AudioSpace] {.async.} =
  if id.len == 0: return
  let cached = await get("sp:" & id)
  if cached.len > 0:
    cached.deserialize(AudioSpace)
  else:
    result = await getAudioSpace(id)
    await cache(result)
  result.m3u8Url = await fetchBroadcastStream(result.mediaKey)

proc cache*(data: AccountInfo; name: string) {.async.} =
  await setEx("ai:" & toLower(name), baseCacheTime * 24, compress(toFlatty(data)))

proc getCachedAccountInfo*(username: string; fetch=true): Future[AccountInfo] {.async.} =
  if username.len == 0: return
  let name = toLower(username)
  let cached = await get("ai:" & name)
  if cached.len > 0:
    cached.deserialize(AccountInfo)
  elif fetch:
    result = await getAboutAccount(username)
    await cache(result, name)

proc getCachedPhotoRail*(id: string): Future[PhotoRail] {.async.} =
  if id.len == 0: return
  let rail = await get("pr2:" & toLower(id))
  if rail.len > 0:
    rail.deserialize(PhotoRail)
  else:
    result = await getPhotoRail(id)
    await cache(result, id)

proc cache*(data: Community) {.async.} =
  if data.id.len == 0: return
  await setEx("cm:" & data.id, listCacheTime, compress(toFlatty(data)))

proc getCachedCommunity*(id: string): Future[Community] {.async.} =
  if id.len == 0: return
  let cached = await get("cm:" & id)
  if cached.len > 0:
    cached.deserialize(Community)
  else:
    result = await getGraphCommunity(id)
    await cache(result)

proc getCachedCommunityModerators*(id: string): Future[seq[User]] {.async.} =
  if id.len == 0: return
  let cached = await get("cmm:" & id)
  if cached.len > 0:
    cached.deserialize(seq[User])
  else:
    let mods = await getGraphCommunityModerators(id)
    result = mods.content
    await setEx("cmm:" & id, listCacheTime, compress(toFlatty(result)))

proc getCachedList*(username=""; slug=""; id=""): Future[List] {.async.} =
  let list = if id.len == 0: ""
             else: await get("l:" & id)

  if list.len > 0:
    list.deserialize(List)
  else:
    if id.len > 0:
      result = await getGraphList(id)
    else:
      result = await getGraphListBySlug(username, slug)
    await cache(result)

proc getCachedRss*(key: string): Future[Rss] {.async.} =
  let k = "rss:" & key
  result.cursor = await get(k & ":min")
  if result.cursor.len > 2:
    if result.cursor != "suspended":
      let feed = await get(k & ":rss")
      if feed.len > 0:
        try: result.feed = uncompress feed
        except: echo "Decompressing RSS failed: ", feed
  else:
    result.cursor.setLen 0
