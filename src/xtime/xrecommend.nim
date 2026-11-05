# x-time tweet-page recommendations: the tweet + a sample of its replies →
# three LLM-written X searches → pooled results → LLM-picked tweets.
# Runs in the background per tweet id; /api/recommend polls a run's progress.
# Only tweets posted at most a month before the opened one are recommended.
import std/[json, asyncdispatch, strutils, tables, sets, algorithm, options, times]
from std/unicode import runeLen, runeSubStr
import karax/vdom
import ".."/[types, api, query, formatters]
import ../views/tweet
from ./xllm import callLlmChat
from ./xconfig import RecommendOpts, LlmProvider
from ./xstore import epochMs

type
  SearchKind = object
    key, name: string
    kind: QueryKind
    minLikes: string

  RecSearch* = object
    key*, name*, label*: string
    query*: Query
    count*: int
    done*: bool
    error*: string

  RecPick* = object
    tweet*: Tweet
    why*: string
    found*: seq[string]   # search keys that returned this tweet

  RecRun* = ref object
    tweetId*: string
    status*: string       # running | done | error
    stage*: int           # 0 reading, 1 writing searches, 2 searching, 3 ranking, 4 finished
    replies*: int
    searches*: seq[RecSearch]
    picks*: seq[RecPick]
    poolSize*: int
    ranker*: string       # llm | likes (fallback when the LLM ranking fails)
    rankError*: string
    error*: string
    startedAt*, finishedAt*: int64

# Each search type has a fixed X ranking + operators; the LLM only writes the keywords.
const searchKinds = [
  SearchKind(key: "core", name: "Core topic", kind: QueryKind.top),
  SearchKind(key: "replies", name: "From the replies", kind: QueryKind.top),
  SearchKind(key: "fresh", name: "Fresh takes", kind: QueryKind.tweets, minLikes: "10")
]

const operatorPrefixes = ["filter:", "min_faves:", "min_retweets:", "min_replies:",
  "lang:", "since:", "until:", "from:", "to:", "include:"]

const maxRuns = 100

var
  recOpts: RecommendOpts
  recEnabled = false      # experimental; toggled from the dashboard's Labs menu
  runs = initTable[string, RecRun]()
  runOrder: seq[string]

proc initRecommend*(opts: RecommendOpts; enabled: bool) =
  recOpts = opts
  recEnabled = enabled

proc recommendEnabled*(): bool = recEnabled

proc setRecommendEnabled*(enabled: bool) =
  recEnabled = enabled

# ---------------------------------------------------------------- text helpers

proc clip(s: string; n: int): string =
  if s.runeLen > n: s.runeSubStr(0, n) else: s

proc plainText(t: Tweet): string =
  stripHtml(t.text).strip()

proc replyText(t: Tweet): string =
  ## Reply text without the leading "@a @b" mentions.
  result = plainText(t)
  while result.startsWith("@"):
    let sp = result.find({' ', '\n'})
    if sp < 0: return ""
    result = result[sp + 1 .. ^1].strip(trailing = false)

proc cleanKeywords(q: string): string =
  ## Drop any operators the LLM adds anyway so searchKinds stays their only source.
  var words: seq[string]
  for w in q.splitWhitespace():
    let bare = w.strip(trailing = false, chars = {'-'}).toLowerAscii()
    var isOperator = false
    for p in operatorPrefixes:
      if bare.startsWith(p): isOperator = true
    if not isOperator: words.add w
  words.join(" ").clip(120)

proc cleanError(msg: string): string =
  ## One line, without the async traceback Nim appends to re-raised errors.
  msg.split("\nAsync traceback:")[0].splitWhitespace().join(" ").clip(300)

proc idStr(n: JsonNode): string =
  if n.isNil: ""
  elif n.kind == JString: n.getStr()
  elif n.kind == JInt: $n.getBiggestInt()
  else: ""

# ---------------------------------------------------------------- prompts

const searchPrompt = """You turn one X (Twitter) post and a sample of its replies into three X searches that surface other posts worth reading.
Write exactly one search of each type:
- "core": the post's central subject — the specific entities, product, event, or claim it is about.
- "replies": the most substantive angle the replies raise that the post itself does not cover — a counterpoint, an open question, an alternative, or a related tool/person/event. If the replies add nothing, take the most interesting neighbouring angle the post implies.
- "fresh": recent takes on the same subject. This one is sorted by latest, so use the shortest query that still pins the subject down.
Query rules:
- 2-5 keywords: the words people would actually write in a post about it, not a description of it.
- Use "double quotes" only around multi-word proper names. OR is allowed, sparingly.
- No @handles, from:/to:, hashtags (unless the post uses them), or operators like min_faves or filter: — those are added for you.
- Write in the post's language.
- The three searches must find different posts — do not reuse the same keyword set.
- "label": 2-4 words naming the angle, shown to the user.
Respond with ONLY a JSON object: {"searches": [{"type": "core", "label": "...", "query": "..."}, {"type": "replies", "label": "...", "query": "..."}, {"type": "fresh", "label": "...", "query": "..."}]}"""

proc rankPrompt(picks: int): string =
  """You recommend X (Twitter) posts to read next, for someone who just opened the post below.
The candidates come from three searches built from that post and its replies (found_by says which).
Pick the $1 best candidates. Prefer posts that:
- teach something: facts, mechanics, data, comparisons, reasoning, or a concrete takeaway related to the post;
- add something the post and its replies do not already say;
- together cover different angles rather than repeating one another.
Never pick: ads, engagement bait, memes, giveaways, low-effort reactions, pure dunking or complaining with no substance, or near-duplicates/retweets of the original post.
If fewer than $1 candidates are worth reading, return fewer.
"why": one short sentence (max ~15 words) on what the pick adds relative to the original post.
Respond with ONLY a JSON object, best first: {"picks": [{"tweet_id": "...", "why": "..."}]}""" % [$picks]

proc promptContext(focal: Tweet; replies: seq[Tweet]): JsonNode =
  var rs = newJArray()
  for r in replies:
    rs.add %*{"author": r.user.username, "text": replyText(r).clip(300)}
  %*{"post": {"author": focal.user.username, "text": plainText(focal)}, "replies": rs}

# ---------------------------------------------------------------- pipeline

proc chat(systemPrompt, userContent: string): Future[JsonNode] {.async.} =
  ## callLlmChat against each configured provider in order until one answers.
  var failures: seq[string]
  for p in recOpts.providers:
    try:
      return await callLlmChat(p.model, p.baseUrl, p.apiKeyEnv,
        systemPrompt, userContent, p.timeoutMs, p.reasoningEffort)
    except CatchableError as e:
      let msg = cleanError(e.msg)
      echo "[xtime] recommend: ", p.name, " (", p.model, ") failed: ", msg
      failures.add p.name & ": " & msg
  raise newException(ValueError, "All LLM providers failed — " & failures.join(" | "))

proc planSearches(focal: Tweet; replies: seq[Tweet]; since: string): Future[seq[RecSearch]] {.async.} =
  let parsed = await chat(searchPrompt, $promptContext(focal, replies))
  for sk in searchKinds:
    for s in parsed{"searches"}.getElems():
      if s{"type"}.getStr() != sk.key: continue
      let keywords = cleanKeywords(s{"query"}.getStr())
      if keywords.len == 0: break
      var label = s{"label"}.getStr().strip()
      if label.len == 0: label = sk.name
      result.add RecSearch(key: sk.key, name: sk.name, label: label,
        query: Query(kind: sk.kind, text: keywords, minLikes: sk.minLikes,
                     excludes: @["replies", "nativeretweets"], since: since))
      break
  if result.len == 0:
    raise newException(ValueError, "LLM returned no usable searches")

proc rankCandidates(focal: Tweet; replies: seq[Tweet]; pool: seq[RecPick];
    picks: int): Future[seq[RecPick]] {.async.} =
  var ctx = promptContext(focal, replies)
  var cands = newJArray()
  for c in pool:
    cands.add %*{"id": $c.tweet.id, "author": c.tweet.user.username,
      "text": plainText(c.tweet).clip(400), "likes": c.tweet.stats.likes,
      "found_by": c.found}
  ctx["candidates"] = cands
  let parsed = await chat(rankPrompt(picks), $ctx)
  let chosen = parsed{"picks"}
  if chosen.isNil or chosen.kind != JArray:
    raise newException(ValueError, "LLM response has no \"picks\" array")
  var byId: Table[string, int]
  for i, c in pool: byId[$c.tweet.id] = i
  var used: HashSet[string]
  for p in chosen:
    let id = idStr(p{"tweet_id"})
    if id notin byId or id in used: continue
    used.incl id
    var pick = pool[byId[id]]
    pick.why = p{"why"}.getStr().strip()
    result.add pick
    if result.len >= picks: break

proc runRecommend(run: RecRun; conv: Conversation) {.async.} =
  try:
    var conv = conv
    if conv.isNil:
      conv = await getTweet(run.tweetId)
    if conv.isNil or conv.tweet.isNil or conv.tweet.id == 0:
      raise newException(ValueError, "Tweet not found")
    # A timeline retweet's own page has no replies; follow it to the original.
    if conv.tweet.retweet.isSome:
      conv = await getTweet($conv.tweet.retweet.get.id)
    let focal = conv.tweet

    var replies: seq[Tweet]
    for chain in conv.replies.content:
      if chain.related or chain.content.len == 0: continue
      let r = chain.content[0]
      if r.isAd or not r.available or replyText(r).len == 0: continue
      replies.add r
      if replies.len >= recOpts.replySample: break
    run.replies = replies.len
    run.stage = 1

    # since: is day-granular, so the pool below also drops anything older
    # than the exact cutoff
    let oldest = if focal.time.isInitialized: focal.time - 1.months
                 else: now().utc - 1.months
    run.searches = await planSearches(focal, replies, oldest.utc.format("yyyy-MM-dd"))
    run.stage = 2
    echo "[xtime] recommend ", run.tweetId, ": searching ",
      run.searches.len, " queries"

    # all searches run concurrently; one failing doesn't sink the others
    var futs: seq[Future[Timeline]]
    for s in run.searches:
      futs.add getGraphTweetSearch(s.query)
    var exclude = toHashSet([run.tweetId, $focal.id])
    for r in replies: exclude.incl $r.id
    var
      pool: seq[RecPick]
      poolIdx: Table[string, int]
    for i, fut in futs:
      try:
        let timeline = await fut
        for group in timeline.content:
          for t in group:
            inc run.searches[i].count
            let id = $t.id
            if id in exclude or t.isAd or not t.available or t.retweet.isSome or
               plainText(t).len == 0 or (t.time.isInitialized and t.time < oldest):
              continue
            if id in poolIdx:
              pool[poolIdx[id]].found.add run.searches[i].key
            else:
              poolIdx[id] = pool.len
              pool.add RecPick(tweet: t, found: @[run.searches[i].key])
      except CatchableError as e:
        run.searches[i].error = cleanError(e.msg)
      run.searches[i].done = true
    run.poolSize = pool.len
    run.stage = 3

    run.ranker = "llm"
    if pool.len > 0:
      try:
        run.picks = await rankCandidates(focal, replies, pool, recOpts.picks)
      except CatchableError as e:
        run.ranker = "likes"
        run.rankError = cleanError(e.msg)
        echo "[xtime] recommend ", run.tweetId, ": ranking failed, using likes: ", run.rankError
        pool.sort(proc (a, b: RecPick): int = cmp(b.tweet.stats.likes, a.tweet.stats.likes))
        run.picks = pool[0 ..< min(recOpts.picks, pool.len)]
    run.stage = 4
    run.status = "done"
  except CatchableError as e:
    run.status = "error"
    run.error = cleanError(e.msg)
    echo "[xtime] recommend ", run.tweetId, " failed: ", run.error
  run.finishedAt = epochMs()
  echo "[xtime] recommend ", run.tweetId, ": ", run.status, " — ", run.picks.len,
    "/", run.poolSize, " picked via ", run.ranker, " in ",
    run.finishedAt - run.startedAt, "ms"

proc evictOldRuns() =
  ## Keep at most maxRuns runs, dropping the oldest finished ones first.
  var i = 0
  while runOrder.len > maxRuns and i < runOrder.len:
    let run = runs.getOrDefault(runOrder[i])
    if run.isNil or run.status != "running":
      runs.del runOrder[i]
      runOrder.delete i
    else:
      inc i

proc ensureRecommend*(id: string; conv: Conversation = nil; refresh = false;
    retryFailed = false): RecRun =
  ## The run for this tweet, starting one if there is none, refresh asks for a
  ## new one, or (retryFailed) the last one errored.
  let existing = runs.getOrDefault(id)
  if not existing.isNil:
    if existing.status == "running": return existing
    if not refresh and not (retryFailed and existing.status == "error"):
      return existing
  result = RecRun(tweetId: id, status: "running", startedAt: epochMs())
  let idx = runOrder.find(id)
  if idx >= 0: runOrder.delete idx
  runOrder.add id
  runs[id] = result
  evictOldRuns()
  asyncCheck runRecommend(result, conv)

proc recommendJson*(run: RecRun; prefs: Prefs; path: string): JsonNode =
  var searches = newJArray()
  for s in run.searches:
    searches.add %*{
      "key": s.key, "name": s.name, "label": s.label,
      "keywords": s.query.text,
      "query": genQueryParam(s.query),
      "url": "/search?" & genQueryUrl(s.query),
      "product": (if s.query.kind == QueryKind.top: "Top" else: "Latest"),
      "count": s.count, "done": s.done, "error": s.error
    }
  var picks = newJArray()
  for p in run.picks:
    picks.add %*{"html": $renderTweet(p.tweet, prefs, path), "why": p.why, "found": p.found}
  let endMs = if run.finishedAt > 0: run.finishedAt else: epochMs()
  %*{
    "tweetId": run.tweetId, "status": run.status, "stage": run.stage,
    "replies": run.replies, "searches": searches, "picks": picks,
    "poolSize": run.poolSize, "ranker": run.ranker, "rankError": run.rankError,
    "error": run.error, "elapsedMs": endMs - run.startedAt,
    "finishedAt": run.finishedAt
  }
