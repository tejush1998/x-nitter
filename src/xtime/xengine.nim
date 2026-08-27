# x-time engine: scrape → classify → translate orchestration (mirror of lib/engine.js)
import std/[json, asyncdispatch, strutils, sets, options, sequtils]
import xconfig, xstore, xscraper, xllm, xstatus

proc tweetsJson*(tweets: seq[Tweet]): JsonNode =
  var items: seq[JsonNode] = @[]
  for tw in tweets:
    var links: JsonNode = newJArray()
    for l in tw.links: links.add %l
    var media: JsonNode = newJArray()
    for m in tw.media: media.add %m
    var item = %*{
      "id": tw.id,
      "text": tw.text,
      "author_id": tw.authorId,
      "author_name": tw.authorName,
      "author_username": tw.authorUsername,
      "created_at": tw.createdAt,
      "like_count": tw.likeCount,
      "retweet_count": tw.retweetCount,
      "reply_count": tw.replyCount,
      "view_count": tw.viewCount,
      "links": links,
      "media": media,
      "promoted": tw.promoted,
      "liked": tw.liked,
      "lang": tw.lang,
      "translation": tw.translation,
      "summary": tw.summary,
      "noise": tw.noise
    }
    if tw.confidence.isSome:
      item["confidence"] = %tw.confidence.get
    items.add item
  %*items

proc assignmentsJson*(assignments: seq[Assignment]): JsonNode =
  var items: seq[JsonNode] = @[]
  for a in assignments:
    var item = %*{
      "tweetId": a.tweetId,
      "topic": a.topic,
      "noise": a.noise
    }
    if a.confidence.isSome:
      item["confidence"] = %a.confidence.get
    if a.lang.len > 0:
      item["lang"] = %a.lang
    items.add item
  %*items

proc persistLanguages*(store: XStore, assignments: seq[Assignment]) =
  var entries: seq[(string, string)] = @[]
  for a in assignments:
    if a.lang.len > 0:
      entries.add (a.tweetId, a.lang)
  store.setTweetLanguages(entries)

proc translateMissing*(store: XStore, tweets: seq[Tweet], conf: XTimeConf) {.async.} =
  ## Translate stored tweets that have a non-English lang and no translation.
  if not conf.translate.enabled: return
  let ids = tweets.mapIt(it.id)
  let need = store.getNeedsTranslation(ids)
  if need.len == 0: return
  try:
    let translations = await translateTweets(need, conf.translate)
    store.setTweetTranslations(translations)
  except CatchableError as e:
    echo "[xtime] translation failed: ", e.msg

proc checkAuth*(conf: XTimeConf) {.async.} =
  let cred = loadCredentials()
  await verifyCredentials(cred)

proc scrapePoll*(store: XStore, conf: XTimeConf, count: int, pages: int,
    source: string, jobId = ""): Future[JsonNode] {.async.} =
  ## One poll: fetch home timeline, insert, classify new, translate.
  beginClassify(source, jobId, 0)
  try:
    let batch = $epochMs()
    let cred = loadCredentials()
    await verifyCredentials(cred)
    let seen = store.getSeenTweetIds(200)
    let tweets = await fetchHomeTimeline(cred, count, pages, seen)
    store.setMeta("last_poll_at", $epochMs())
    let newIds = store.insertTweets(tweets, batch)

    var toClassify: seq[Tweet] = @[]
    if tweets.len > 0:
      var unassigned = initHashSet[string]()
      for id in store.getUnassignedTweetIds(tweets.mapIt(it.id)):
        unassigned.incl id
      for tw in tweets:
        if unassigned.contains(tw.id):
          toClassify.add tw

    var assignments: seq[Assignment] = @[]
    if toClassify.len > 0:
      assignments = await classifyTweets(toClassify, conf.classify)
      if assignments.len > 0:
        store.assignTopics(assignments)
        persistLanguages(store, assignments)

    await translateMissing(store, tweets, conf)
    finishClassify(true, message = "Classified " & $assignments.len &
      " of " & $toClassify.len & " new tweets")
    return %*{
      "total": tweets.len,
      "newCount": newIds.len,
      "assignments": assignmentsJson(assignments),
      "batch": batch
    }
  except CatchableError as e:
    finishClassify(false, error = e.msg)
    raise

proc classifyStoredUnassigned*(store: XStore, conf: XTimeConf,
    batch: string, source = "auto", jobId = ""): Future[JsonNode] {.async.} =
  ## Classify stored tweets that have no topic assignment yet.
  beginClassify(source, jobId, 0)
  try:
    let tweets = store.getUnassignedTweets(500, batch)
    if tweets.len == 0:
      finishClassify(true, message = "No unassigned tweets")
      return %*{"total": 0, "assignments": [], "batch": batch}
    let assignments = await classifyTweets(tweets, conf.classify)
    if assignments.len > 0:
      store.assignTopics(assignments)
      persistLanguages(store, assignments)
    await translateMissing(store, tweets, conf)
    finishClassify(true, message = "Classified " & $assignments.len & " tweets")
    return %*{
      "total": tweets.len,
      "assignments": assignmentsJson(assignments),
      "batch": batch
    }
  except CatchableError as e:
    finishClassify(false, error = e.msg)
    raise

proc classifyStored*(store: XStore, conf: XTimeConf, batch: string,
    source = "reclassify", jobId = ""): Future[JsonNode] {.async.} =
  ## Reclassify all stored tweets (clears existing assignments first).
  let tweets = store.getStoredTweets(500, batch)
  if tweets.len == 0:
    raise newException(ValueError, "No tweets to reclassify. Run a scrape first.")
  beginClassify(source, jobId, 0)
  try:
    store.clearTopicAssignments(tweets.mapIt(it.id))
    let assignments = await classifyTweets(tweets, conf.classify)
    if assignments.len > 0:
      store.assignTopics(assignments)
      persistLanguages(store, assignments)
    await translateMissing(store, tweets, conf)
    finishClassify(true, message = "Classified " & $assignments.len & " tweets")
    return %*{
      "total": tweets.len,
      "assignments": assignmentsJson(assignments),
      "batch": batch
    }
  except CatchableError as e:
    finishClassify(false, error = e.msg)
    raise

proc recentSeenIds*(store: XStore, limit = 200): seq[string] =
  store.getSeenTweetIds(limit)

proc pollTooSoonNow*(store: XStore, minSec: int): Option[int] =
  ## Seconds to wait before next poll, or none if allowed now.
  let last = store.getMetaInt("last_poll_at")
  if last.isNone: return none(int)
  let elapsedMs = epochMs() - last.get
  let minMs = minSec * 1000
  if elapsedMs < minMs:
    some(int((minMs - elapsedMs + 999) div 1000))
  else:
    none(int)

proc getFeedSnapshot*(store: XStore, conf: XTimeConf, includeNoise: bool,
    batch: string, likedOnly: bool): JsonNode =
  let batches = store.getBatches()
  var currentBatch = batch
  if currentBatch.len > 0:
    var found = false
    for b in batches:
      if b.id == currentBatch: found = true
    if not found: currentBatch = ""
  if currentBatch.len == 0:
    currentBatch = store.getLatestBatch()

  let stats = %*{
    "totalTweets": store.countTweets(currentBatch),
    "assigned": store.countAssignedTweets(currentBatch),
    "noise": store.countNoiseAssignments(currentBatch),
    "liked": store.countLiked(currentBatch),
    "lastPollAt": store.getMeta("last_poll_at")
  }

  var batchesJson: seq[JsonNode] = @[]
  for b in batches:
    batchesJson.add %*{"id": b.id, "count": b.count, "latest": b.latest}

  var rows: seq[JsonNode] = @[]
  if likedOnly:
    let likedTopics = store.getLikedTopicsView(includeNoise, currentBatch)
    var shown = initHashSet[string]()
    for topicRow in likedTopics:
      let topicTweets = store.getLikedTweetsByTopic(topicRow.topic, 100,
        includeNoise, currentBatch)
      for tw in topicTweets:
        shown.incl tw.id
      var latest: JsonNode = if topicRow.latest.len > 0: %topicRow.latest else: newJNull()
      rows.add %*{
        "topic": topicRow.topic,
        "count": topicRow.count,
        "latest": latest,
        "tweets": tweetsJson(topicTweets)
      }
    let allLiked = store.getLikedTweets(currentBatch)
    var unsorted: seq[Tweet] = @[]
    for tw in allLiked:
      if not shown.contains(tw.id):
        unsorted.add tw
    rows.add %*{
      "topic": "Unsorted",
      "count": unsorted.len,
      "latest": newJNull(),
      "tweets": tweetsJson(unsorted)
    }
  else:
    let topics = store.getTopicsView(includeNoise, currentBatch)
    for topicRow in topics:
      let topicTweets = store.getTweetsByTopic(topicRow.topic, 20,
        includeNoise, currentBatch)
      var latest: JsonNode = if topicRow.latest.len > 0: %topicRow.latest else: newJNull()
      rows.add %*{
        "topic": topicRow.topic,
        "count": topicRow.count,
        "latest": latest,
        "tweets": tweetsJson(topicTweets)
      }

  %*{
    "stats": stats,
    "batches": batchesJson,
    "currentBatch": currentBatch,
    "rows": rows,
    "likedOnly": likedOnly,
    "linkBase": conf.linkBase
  }
