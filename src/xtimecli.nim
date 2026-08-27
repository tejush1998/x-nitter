# x-time CLI: poll / view / reclassify (replaces index.js)
import std/[os, strutils, json, asyncdispatch, times, options, algorithm, parseopt, sequtils, sets, tables]
import xtime/[xconfig, xstore, xscraper, xllm, xstatus, xengine]

type CliFlags = object
  topics: string
  pages: int
  showNoise: bool
  batch: string
  batchSet: bool
  view: bool
  reclassify: bool

proc printTweet(tw: Tweet, assignment: Assignment, showNoise: bool) =
  var line = "  [" & tw.id & "] @" & tw.authorUsername & " · " & tw.createdAt
  if assignment.noise:
    line.add " · [NOISE"
    if assignment.confidence.isSome:
      line.add " " & $(assignment.confidence.get * 100).int & "%"
    line.add "]"
  echo line
  for l in tw.text.split('\n'):
    echo "      ", l

proc printView(store: XStore, conf: XTimeConf, batch: string, showNoise: bool) =
  let topics = store.getTopicsView(showNoise, batch)
  if topics.len == 0:
    echo "No classified tweets", (if batch.len > 0: " in batch " & batch else: ""), "."
    return
  for t in topics:
    echo t.topic, " (", t.count, ")"
    let tweets = store.getTweetsByTopic(t.topic, 5, showNoise, batch)
    let assignments = store.getTopicAssignments(tweets.mapIt(it.id))
    for tw in tweets:
      var a: Assignment
      if assignments.hasKey(tw.id):
        a = assignments[tw.id]
      else:
        a = Assignment(tweetId: tw.id, topic: t.topic)
      printTweet(tw, a, showNoise)
    echo ""
  let noise = store.countNoiseAssignments(batch)
  if noise > 0 and not showNoise:
    echo "(", noise, " hidden — pass --noise to show)"

proc classifyInto(store: XStore, conf: XTimeConf, tweets: seq[Tweet]): Future[seq[Assignment]] {.async.} =
  beginClassify("cli", "", tweets.len)
  try:
    let assignments = await classifyTweets(tweets, conf.classify)
    if assignments.len > 0:
      store.assignTopics(assignments)
      persistLanguages(store, assignments)
    var noise = 0
    for a in assignments:
      if a.noise: noise.inc
    finishClassify(true, message = "Classified " & $assignments.len & " tweets")
    echo "Classified ", assignments.len, " tweets as new (", noise, " noise)"
    return assignments
  except CatchableError as e:
    finishClassify(false, error = e.msg)
    raise

proc runAsync(flags: CliFlags) {.async.} =
  let conf = loadXTimeConf()
  let store = openStore()

  if flags.view:
    var batch = flags.batch
    if batch == "all": batch = ""
    elif batch.len == 0: batch = store.getLatestBatch()
    printView(store, conf, batch, flags.showNoise)
    return

  if flags.reclassify:
    var batch = flags.batch
    if batch == "all": batch = ""
    elif batch.len == 0: batch = store.getLatestBatch()
    let tweets = store.getStoredTweets(500, batch)
    if tweets.len == 0:
      echo "No tweets to reclassify. Run a poll first."
      quit(1)
    store.clearTopicAssignments(tweets.mapIt(it.id))
    let assignments = await classifyInto(store, conf, tweets)
    echo "Reclassified ", assignments.len, " tweets"
    var b2 = flags.batch
    if b2 == "all": b2 = ""
    elif b2.len == 0: b2 = store.getLatestBatch()
    printView(store, conf, b2, flags.showNoise)
    return

  # default: scrape + classify + translate
  let remaining = pollTooSoonNow(store, conf.minPollIntervalSec)
  if remaining.isSome:
    echo "Poll too soon. Last poll was ", remaining.get, "s ago (min ",
      conf.minPollIntervalSec, "s)"
    quit(1)

  let cred = loadCredentials()
  await verifyCredentials(cred)

  let batch = $epochMs()
  let seen = store.getSeenTweetIds(200)
  let pages = if flags.pages > 0: flags.pages else: conf.pages
  let tweets = await fetchHomeTimeline(cred, conf.countPerPage, pages, seen)
  store.setMeta("last_poll_at", $epochMs())
  let newIds = store.insertTweets(tweets, batch)

  var toClassify: seq[Tweet] = @[]
  if tweets.len > 0:
    var unassigned = toHashSet(store.getUnassignedTweetIds(tweets.mapIt(it.id)))
    for tw in tweets:
      if unassigned.contains(tw.id):
        toClassify.add tw

  var noise = 0
  if toClassify.len > 0:
    let assignments = await classifyInto(store, conf, toClassify)
    for a in assignments:
      if a.noise: noise.inc

  # translate
  if conf.translate.enabled:
    let need = store.getNeedsTranslation(tweets.mapIt(it.id))
    if need.len > 0:
      let translations = await translateTweets(need, conf.translate)
      store.setTweetTranslations(translations)
      echo "Translated ", translations.len, " tweets"

  echo ""
  echo "Scraped ", tweets.len, " tweets (", newIds.len, " new)"
  echo "Classified ", toClassify.len, " tweets as new (", noise, " noise)"
  echo "Batch: ", batch

proc fail(msg: string, code: int) =
  stderr.writeLine(msg)
  quit(code)

when isMainModule:
  loadDotEnv()
  var flags = CliFlags()
  for kind, key, val in getopt():
    case kind
    of cmdLongOption:
      case key
      of "topics": flags.topics = val
      of "pages":
        try: flags.pages = parseInt(val)
        except: discard
      of "noise": flags.showNoise = true
      of "batch": flags.batch = val; flags.batchSet = true
      of "view": flags.view = true
      of "reclassify": flags.reclassify = true
      else: discard
    of cmdShortOption:
      case key
      of "v": flags.view = true
      of "n": flags.showNoise = true
      else: discard
    else: discard

  try:
    waitFor runAsync(flags)
  except XAuthError as e:
    fail(e.msg, 2)
  except CatchableError as e:
    fail(e.msg, 1)
