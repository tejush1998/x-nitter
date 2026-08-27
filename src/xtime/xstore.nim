# x-time persistent store: SQLite (mirror of lib/store.js)
import std/[json, os, strutils, times, options, algorithm, tables, sets, sequtils]
import ./vendor/db_sqlite

type
  Assignment* = object
    tweetId*: string
    topic*: string
    confidence*: Option[float]
    noise*: bool
    lang*: string
    summary*: string

  Tweet* = ref object
    id*: string
    text*: string
    authorId*: string
    authorName*: string
    authorUsername*: string
    createdAt*: string
    likeCount*: int
    retweetCount*: int
    replyCount*: int
    viewCount*: int
    links*: seq[string]
    media*: seq[string]
    promoted*: bool
    raw*: string
    fetchedAt*: string
    batch*: string
    liked*: bool
    lang*: string
    translation*: string
    summary*: string
    confidence*: Option[float]
    noise*: bool

  TopicRow* = object
    topic*: string
    count*: int
    latest*: string

  BatchRow* = object
    id*: string
    count*: int
    latest*: string

  XStore* = ref object
    db: DbConn

proc nowIso*(): string =
  now().utc().format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")

proc epochMs*(): int64 =
  let t = getTime()
  t.toUnix * 1000 + (t.nanosecond div 1_000_000)

proc esc*(s: string): string =
  # SQLite literal escaping; "??" escapes the placeholder parser's "?"
  "'" & s.replace("'", "''").replace("?", "??") & "'"

proc toIntSafe(s: string, default = 0): int =
  try: parseInt(s.strip()) except: default

proc jsonArrField(val: string): seq[string] =
  if val.len == 0: return @[]
  try:
    let j = parseJson(val)
    if j.kind == JArray:
      for item in j:
        if item.kind == JString: result.add item.getStr()
  except: discard

proc rowToTweet(r: Row): Tweet =
  let promoted = r[12]
  let liked = r[16]
  Tweet(
    id: r[0],
    text: r[1],
    authorId: r[2],
    authorName: r[3],
    authorUsername: r[4],
    createdAt: r[5],
    likeCount: toIntSafe(r[6]),
    retweetCount: toIntSafe(r[7]),
    replyCount: toIntSafe(r[8]),
    viewCount: toIntSafe(r[9]),
    links: jsonArrField(r[10]),
    media: jsonArrField(r[11]),
    promoted: promoted == "1" or promoted == "true",
    raw: r[13],
    fetchedAt: r[14],
    batch: r[15],
    liked: liked == "1",
    lang: "",
    translation: "",
    summary: ""
  )

proc tweetFromRowWithExtras(r: Row): Tweet =
  result = rowToTweet(r)
  # joined queries append: confidence, noise, lang, translation, summary
  let n = r.len
  if n > 17 and r[17].len > 0:
    try: result.confidence = some(parseFloat(r[17]))
    except: discard
  if n > 18: result.noise = r[18] == "1"
  if n > 19: result.lang = r[19]
  if n > 20: result.translation = r[20]
  if n > 21: result.summary = r[21]

const tweetCols* = "id, text, author_id, author_name, author_username, created_at, " &
  "like_count, retweet_count, reply_count, view_count, links, media, promoted, " &
  "raw, fetched_at, batch, liked"

proc openStore*(path = "feed.db"): XStore =
  let db = open(connection = path, user = "", password = "", database = "")
  db.exec(sql"PRAGMA journal_mode=WAL")
  db.exec(sql"PRAGMA busy_timeout=5000")
  db.exec(sql"""CREATE TABLE IF NOT EXISTS tweets (
    id TEXT PRIMARY KEY,
    text TEXT NOT NULL,
    author_id TEXT,
    author_name TEXT,
    author_username TEXT,
    created_at TEXT,
    like_count INTEGER DEFAULT 0,
    retweet_count INTEGER DEFAULT 0,
    reply_count INTEGER DEFAULT 0,
    view_count INTEGER DEFAULT 0,
    links TEXT,
    media TEXT,
    promoted INTEGER DEFAULT 0,
    raw TEXT,
    fetched_at TEXT,
    batch TEXT,
    liked INTEGER DEFAULT 0
  )""")
  db.exec(sql"""CREATE TABLE IF NOT EXISTS topics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL
  )""")
  db.exec(sql"""CREATE TABLE IF NOT EXISTS tweet_topics (
    tweet_id TEXT NOT NULL REFERENCES tweets(id),
    topic_id INTEGER NOT NULL REFERENCES topics(id),
    confidence REAL,
    noise INTEGER DEFAULT 0,
    PRIMARY KEY (tweet_id, topic_id)
  )""")
  db.exec(sql"""CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT
  )""")

  var cols: HashSet[string]
  for row in db.getAllRows(sql"PRAGMA table_info(tweets)"):
    cols.incl row[1]
  template addCol(name: string, ddl: string) =
    if not cols.contains(name):
      db.exec(sql("ALTER TABLE tweets ADD COLUMN " & ddl))
  addCol("noise", "noise INTEGER DEFAULT 0")
  addCol("batch", "batch TEXT")
  addCol("liked", "liked INTEGER DEFAULT 0")
  addCol("lang", "lang TEXT")
  addCol("translation", "translation TEXT")
  addCol("summary", "summary TEXT")

  # legacy batch backfill (epoch ms of fetched_at, fallback created_at)
  db.exec(sql"""UPDATE tweets SET batch = CAST(CAST(strftime('%s', fetched_at) AS INTEGER) * 1000 AS TEXT)
    WHERE (batch IS NULL OR batch = '0') AND fetched_at IS NOT NULL""")
  db.exec(sql"""UPDATE tweets SET batch = CAST(CAST(strftime('%s', created_at) AS INTEGER) * 1000 AS TEXT)
    WHERE (batch IS NULL OR batch = '0') AND created_at IS NOT NULL""")

  XStore(db: db)

proc getMeta*(store: XStore, key: string): string =
  store.db.getValue(sql("SELECT value FROM meta WHERE key = " & esc(key)))

proc setMeta*(store: XStore, key: string, value: string) =
  store.db.exec(sql("INSERT INTO meta (key, value) VALUES (" & esc(key) & ", " & esc(value) & ")" &
    " ON CONFLICT(key) DO UPDATE SET value = excluded.value"))

proc getMetaInt*(store: XStore, key: string): Option[int64] =
  let v = store.getMeta(key)
  if v.len == 0: none(int64) else: some(v.parseInt.int64)

proc getTweetById*(store: XStore, id: string): Tweet =
  let rows = store.db.getAllRows(sql(
    "SELECT " & tweetCols & ", NULL, 0, lang, translation, summary FROM tweets WHERE id = " & esc(id)))
  if rows.len == 0: return nil
  tweetFromRowWithExtras(rows[0])

proc insertTweets*(store: XStore, tweets: seq[Tweet], batch: string): seq[string] =
  ## Insert tweets; update text/fetched_at/batch for rows that already exist.
  ## Returns ids that were newly inserted.
  let fetched = nowIso()
  for tw in tweets:
    let links = if tw.links.len > 0: $(%*tw.links) else: "[]"
    let media = if tw.media.len > 0: $(%*tw.media) else: "[]"
    let exists = store.db.getValue(sql("SELECT 1 FROM tweets WHERE id = " & esc(tw.id)))
    if exists.len > 0:
      store.db.exec(sql("UPDATE tweets SET text = " & esc(tw.text) & ", fetched_at = " &
        esc(fetched) & ", batch = " & esc(batch) & " WHERE id = " & esc(tw.id)))
    else:
      store.db.exec(sql("INSERT INTO tweets " &
        "(id, text, author_id, author_name, author_username, created_at, " &
        "like_count, retweet_count, reply_count, view_count, links, media, " &
        "promoted, raw, fetched_at, batch, liked) VALUES (" &
        esc(tw.id) & ", " & esc(tw.text) & ", " & esc(tw.authorId) & ", " & esc(tw.authorName) & ", " &
        esc(tw.authorUsername) & ", " & esc(tw.createdAt) & ", " & $tw.likeCount & ", " & $tw.retweetCount & ", " &
        $tw.replyCount & ", " & $tw.viewCount & ", " & esc(links) & ", " & esc(media) & ", " &
        $(if tw.promoted: 1 else: 0) & ", " & esc(tw.raw) & ", " & esc(fetched) & ", " & esc(batch) & ", 0)"))
      result.add tw.id

proc getSeenTweetIds*(store: XStore, limit = 100): seq[string] =
  for row in store.db.getAllRows(sql("SELECT id FROM tweets ORDER BY fetched_at DESC LIMIT " & $limit)):
    result.add row[0]

proc getUnassignedTweetIds*(store: XStore, ids: seq[string]): seq[string] =
  if ids.len == 0: return @[]
  var i = 0
  while i < ids.len:
    let chunk = ids[i ..< min(i + 500, ids.len)]
    let parts = chunk.mapIt(esc(it))
    let q = "SELECT id FROM tweets WHERE id IN (" & parts.join(",") & ")" &
      " AND id NOT IN (SELECT tweet_id FROM tweet_topics)"
    for row in store.db.getAllRows(sql(q)):
      result.add row[0]
    i += 500

proc getUnassignedTweets*(store: XStore, limit = 500, batch = ""): seq[Tweet] =
  var q = "SELECT " & tweetCols & ", NULL, 0, lang, translation, summary FROM tweets " &
    "WHERE id NOT IN (SELECT tweet_id FROM tweet_topics)"
  if batch.len > 0:
    q.add " AND batch = " & esc(batch)
  q.add " ORDER BY COALESCE(created_at, fetched_at) DESC, fetched_at DESC LIMIT " & $limit
  for row in store.db.getAllRows(sql(q)):
    result.add tweetFromRowWithExtras(row)

proc setTweetLiked*(store: XStore, id: string, liked: bool) =
  store.db.exec(sql("UPDATE tweets SET liked = " & $(if liked: 1 else: 0) & " WHERE id = " & esc(id)))

proc setTweetLanguages*(store: XStore, entries: seq[(string, string)]) =
  for (id, lang) in entries:
    if lang.len == 0: continue
    store.db.exec(sql("UPDATE tweets SET lang = " & esc(lang) & " WHERE id = " & esc(id)))

proc setTweetTranslations*(store: XStore, entries: seq[(string, string)]) =
  for (id, translation) in entries:
    if translation.len == 0: continue
    store.db.exec(sql("UPDATE tweets SET translation = " & esc(translation) & " WHERE id = " & esc(id)))

proc setTweetSummaries*(store: XStore, entries: seq[(string, string)]) =
  for (id, summary) in entries:
    if summary.len == 0: continue
    store.db.exec(sql("UPDATE tweets SET summary = " & esc(summary) & " WHERE id = " & esc(id)))

proc getNeedsTranslation*(store: XStore, ids: seq[string]): seq[Tweet] =
  if ids.len == 0: return @[]
  var i = 0
  while i < ids.len:
    let chunk = ids[i ..< min(i + 500, ids.len)]
    let parts = chunk.mapIt(esc(it))
    let q = "SELECT " & tweetCols & ", NULL, 0, lang, translation, summary FROM tweets WHERE id IN (" &
      parts.join(",") & ")" &
      " AND lang IS NOT NULL AND lang NOT IN ('en','eng') AND (translation IS NULL OR translation = '')"
    for row in store.db.getAllRows(sql(q)):
      result.add tweetFromRowWithExtras(row)
    i += 500

proc countTweets*(store: XStore, batch = ""): int =
  if batch.len > 0:
    store.db.getValue(sql("SELECT COUNT(*) FROM tweets WHERE batch = " & esc(batch))).parseInt
  else:
    store.db.getValue(sql"SELECT COUNT(*) FROM tweets").parseInt

proc countLiked*(store: XStore, batch = ""): int =
  if batch.len > 0:
    store.db.getValue(sql("SELECT COUNT(*) FROM tweets WHERE liked = 1 AND batch = " & esc(batch))).parseInt
  else:
    store.db.getValue(sql"SELECT COUNT(*) FROM tweets WHERE liked = 1").parseInt

proc countNoiseAssignments*(store: XStore, batch = ""): int =
  if batch.len > 0:
    store.db.getValue(sql("""SELECT COUNT(DISTINCT tt.tweet_id) FROM tweet_topics tt
      JOIN tweets tw ON tw.id = tt.tweet_id WHERE tt.noise = 1 AND tw.batch = """ & esc(batch))).parseInt
  else:
    store.db.getValue(sql"SELECT COUNT(DISTINCT tweet_id) FROM tweet_topics WHERE noise = 1").parseInt

proc countAssignedTweets*(store: XStore, batch = ""): int =
  if batch.len > 0:
    store.db.getValue(sql("""SELECT COUNT(DISTINCT tt.tweet_id) FROM tweet_topics tt
      JOIN tweets tw ON tw.id = tt.tweet_id WHERE tw.batch = """ & esc(batch))).parseInt
  else:
    store.db.getValue(sql"SELECT COUNT(DISTINCT tweet_id) FROM tweet_topics").parseInt

proc getLikedTweets*(store: XStore, batch = ""): seq[Tweet] =
  var q = "SELECT " & tweetCols & ", NULL, 0, lang, translation, summary FROM tweets WHERE liked = 1"
  if batch.len > 0:
    q.add " AND batch = " & esc(batch)
  q.add " ORDER BY COALESCE(created_at, fetched_at) DESC"
  for row in store.db.getAllRows(sql(q)):
    result.add tweetFromRowWithExtras(row)

proc getLikedTopicsView*(store: XStore, includeNoise: bool, batch = ""): seq[TopicRow] =
  var q = """SELECT t.name topic, COUNT(tt.tweet_id) count, MAX(tw.created_at) latest
    FROM tweet_topics tt
    JOIN tweets tw ON tw.id = tt.tweet_id AND tw.liked = 1
    JOIN topics t ON t.id = tt.topic_id"""
  if not includeNoise:
    q.add " WHERE tt.noise = 0"
  if batch.len > 0:
    q.add (if not includeNoise: " AND" else: " WHERE") & " tw.batch = " & esc(batch)
  q.add " GROUP BY t.id HAVING count > 0 ORDER BY count DESC, t.name"
  for row in store.db.getAllRows(sql(q)):
    result.add TopicRow(topic: row[0], count: row[1].parseInt, latest: row[2])

proc getLikedTweetsByTopic*(store: XStore, topic: string, limit = 100,
    includeNoise = false, batch = ""): seq[Tweet] =
  var q = "SELECT tw.*, tt.confidence, tt.noise, tw.lang, tw.translation, tw.summary FROM tweets tw" &
    " JOIN tweet_topics tt ON tt.tweet_id = tw.id" &
    " JOIN topics t ON t.id = tt.topic_id AND tw.liked = 1 WHERE t.name = " & esc(topic)
  if not includeNoise:
    q.add " AND tt.noise = 0"
  if batch.len > 0:
    q.add " AND tw.batch = " & esc(batch)
  q.add " ORDER BY COALESCE(tw.created_at, tw.fetched_at) DESC, tw.fetched_at DESC LIMIT " & $limit
  for row in store.db.getAllRows(sql(q)):
    result.add tweetFromRowWithExtras(row)

proc getTopicId*(store: XStore, name: string): int =
  store.db.exec(sql("INSERT OR IGNORE INTO topics (name) VALUES (" & esc(name) & ")"))
  store.db.getValue(sql("SELECT id FROM topics WHERE name = " & esc(name))).parseInt

proc assignTopics*(store: XStore, assignments: seq[Assignment]) =
  for a in assignments:
    let topicId = store.getTopicId(a.topic)
    store.db.exec(sql("DELETE FROM tweet_topics WHERE tweet_id = " & esc(a.tweetId)))
    store.db.exec(sql("INSERT OR REPLACE INTO tweet_topics (tweet_id, topic_id, confidence, noise) VALUES (" &
      esc(a.tweetId) & ", " & $topicId & ", " &
      (if a.confidence.isSome: $a.confidence.get else: "NULL") & ", " &
      $(if a.noise: 1 else: 0) & ")"))

proc clearTopicAssignments*(store: XStore, ids: seq[string]) =
  if ids.len == 0: return
  var i = 0
  while i < ids.len:
    let chunk = ids[i ..< min(i + 500, ids.len)]
    let parts = chunk.mapIt(esc(it))
    store.db.exec(sql("DELETE FROM tweet_topics WHERE tweet_id IN (" & parts.join(",") & ")"))
    i += 500

proc getStoredTweets*(store: XStore, limit = 500, batch = ""): seq[Tweet] =
  var q = "SELECT " & tweetCols & ", NULL, 0, lang, translation, summary FROM tweets"
  if batch.len > 0:
    q.add " WHERE batch = " & esc(batch)
  q.add " ORDER BY COALESCE(created_at, fetched_at) DESC, fetched_at DESC LIMIT " & $limit
  for row in store.db.getAllRows(sql(q)):
    result.add tweetFromRowWithExtras(row)

proc getBatches*(store: XStore): seq[BatchRow] =
  for row in store.db.getAllRows(sql("""SELECT batch, COUNT(*) count,
      MAX(COALESCE(created_at, fetched_at)) latest FROM tweets
      WHERE batch IS NOT NULL AND batch != ''
      GROUP BY batch""")):
    result.add BatchRow(id: row[0], count: row[1].parseInt, latest: row[2])
  result.sort(proc(a, b: BatchRow): int =
    let c = cmp(b.latest, a.latest)
    if c != 0: return c
    cmp(toIntSafe(b.id, -1), toIntSafe(a.id, -1)))

proc getLatestBatch*(store: XStore): string =
  let batches = store.getBatches()
  if batches.len == 0: "" else: batches[0].id

proc hasBatchOnDay*(store: XStore, date: DateTime): bool =
  let dayStart = date - (date.hour * 3600 + date.minute * 60 + date.second).seconds
  let startMs = toTime(dayStart).toUnix * 1000
  let endMs = startMs + 86_399_999
  for row in store.db.getAllRows(sql"SELECT DISTINCT batch FROM tweets WHERE batch IS NOT NULL AND batch != ''"):
    let ms = toIntSafe(row[0], -1)
    if ms >= startMs and ms <= endMs: return true
  return false

proc getTopicAssignments*(store: XStore, ids: seq[string]): Table[string, Assignment] =
  var i = 0
  while i < ids.len:
    let chunk = ids[i ..< min(i + 500, ids.len)]
    let parts = chunk.mapIt(esc(it))
    let q = """SELECT tt.tweet_id, t.name, tt.confidence, tt.noise FROM tweet_topics tt
      JOIN topics t ON t.id = tt.topic_id WHERE tt.tweet_id IN (""" & parts.join(",") & ")"
    for row in store.db.getAllRows(sql(q)):
      var conf: Option[float] = none(float)
      if row[2].len > 0:
        try: conf = some(parseFloat(row[2]))
        except: discard
      result[row[0]] = Assignment(
        tweetId: row[0], topic: row[1], confidence: conf, noise: row[3] == "1")
    i += 500

proc getTopicsView*(store: XStore, includeNoise: bool, batch = ""): seq[TopicRow] =
  var q = """SELECT t.name topic, COUNT(tt.tweet_id) count, MAX(tw.created_at) latest
    FROM topics t
    CROSS JOIN tweet_topics tt ON tt.topic_id = t.id
    JOIN tweets tw ON tw.id = tt.tweet_id"""
  if not includeNoise:
    q.add " WHERE tt.noise = 0"
  if batch.len > 0:
    q.add (if not includeNoise: " AND" else: " WHERE") & " tw.batch = " & esc(batch)
  q.add " GROUP BY t.id HAVING count > 0 ORDER BY count DESC, t.name"
  for row in store.db.getAllRows(sql(q)):
    result.add TopicRow(topic: row[0], count: row[1].parseInt, latest: row[2])

proc getTweetsByTopic*(store: XStore, topic: string, limit = 20,
    includeNoise = false, batch = ""): seq[Tweet] =
  var q = "SELECT tw.*, tt.confidence, tt.noise, tw.lang, tw.translation, tw.summary FROM tweets tw" &
    " JOIN tweet_topics tt ON tt.tweet_id = tw.id" &
    " JOIN topics t ON t.id = tt.topic_id WHERE t.name = " & esc(topic)
  if not includeNoise:
    q.add " AND tt.noise = 0"
  if batch.len > 0:
    q.add " AND tw.batch = " & esc(batch)
  q.add " ORDER BY COALESCE(tw.created_at, tw.fetched_at) DESC, tw.fetched_at DESC LIMIT " & $limit
  for row in store.db.getAllRows(sql(q)):
    result.add tweetFromRowWithExtras(row)
