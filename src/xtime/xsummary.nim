# x-time profile summaries (the ✦ button on profiles): a user's own posts from
# the last two weeks (originals, quotes and replies, no plain retweets) → one
# LLM call → the topics they post about and their stance on each.
# Results stay in SQLite (user_summaries) until refreshed from the modal.
import std/[json, asyncdispatch, strutils, tables, sets, options, times]
from std/unicode import runeLen, runeSubStr
import ".."/[types, api, formatters, caching]
from ./xllm import callLlmChat
from ./xconfig import SummaryOpts
from ./xstore import XStore, epochMs, nowIso, getUserSummary, setUserSummary

type
  SumRun = ref object
    username: string
    status: string        # running | error (done runs are dropped; the result is in SQLite)
    stage: int            # 0 fetching posts, 1 summarizing
    fetched: int
    error: string
    startedAt: int64

  Post = object
    tweet: Tweet
    parent: Tweet         # the post it replies to, when the timeline included it

var
  sumOpts: SummaryOpts
  sumStore: XStore
  runs = initTable[string, SumRun]()

proc initSummary*(opts: SummaryOpts; store: XStore) =
  sumOpts = opts
  sumStore = store

proc clip(s: string; n: int): string =
  if s.runeLen > n: s.runeSubStr(0, n) & "…" else: s

proc plainText(t: Tweet): string =
  stripHtml(t.text).strip()

proc cleanError(msg: string): string =
  msg.split("\nAsync traceback:")[0].splitWhitespace().join(" ").clip(300)

const summaryPrompt = """You profile an X (Twitter) user from their own posts over the last two weeks: original posts, quote posts and replies. Posts they replied to or quoted are included for context only; other people wrote those.
Find the 3-6 topics they post about most, most-discussed first. For each topic:
- "name": 2-4 words.
- "line": ONE short sentence (at most ~20 words) on their opinion, leaning or bias on it, as their posts show it. If they only share news or ask questions about it, say that instead.
Also write "overview": one sentence on what this account mostly posts about and how it comes across.
Rules: describe only what the posts show and do not guess at views they never express. Never attribute replied-to or quoted text to this user. Ignore greetings, thanks and one-word replies. Write in English. Keep every line short.
Respond with ONLY a JSON object: {"overview": "...", "topics": [{"name": "...", "line": "..."}]}"""

proc collect(run: SumRun; user: User): Future[seq[Post]] {.async.} =
  ## Newest-first own posts within the window, up to maxTweets, paging the
  ## Replies tab until a page reaches past the cutoff.
  let cutoff = now().utc - sumOpts.days.days
  let me = user.username.toLowerAscii()
  var
    seen: HashSet[int64]
    cursor = ""
  for page in 0 ..< sumOpts.maxPages:
    let prof = await getGraphUserTweets(user.id, TimelineKind.replies, cursor)
    var reachedCutoff = false
    for chain in prof.tweets.content:
      for t in chain:
        if t.isNil or t.id == 0 or t.user.username.toLowerAscii() != me: continue
        if t.retweet.isSome or t.isAd or not t.available or not t.time.isInitialized: continue
        if t.time < cutoff:
          # only the entry's own tweet (a chain's last) marks the end; earlier
          # ones can be old posts of theirs that a new reply answers
          if not t.pinned and t.id == chain[^1].id: reachedCutoff = true
          continue
        if t.id in seen: continue
        seen.incl t.id
        var post = Post(tweet: t)
        if t.replyId != 0:
          for p in chain:
            if p.id == t.replyId: post.parent = p
        result.add post
        run.fetched = result.len
        if result.len >= sumOpts.maxTweets: return
    echo "[xtime] summary @", user.username, ": page ", page + 1, ", ", result.len, " posts",
      (if reachedCutoff: ", reached the cutoff" else: "")
    let next = prof.tweets.bottom
    if reachedCutoff or next.len == 0 or next == cursor: break
    cursor = next

proc promptInput(user: User; posts: seq[Post]): JsonNode =
  var items = newJArray()
  for i, p in posts:
    let t = p.tweet
    var item = %*{
      "date": t.time.utc.format("yyyy-MM-dd"),
      "kind": (if t.replyId != 0: "reply" elif t.quote.isSome: "quote" else: "post"),
      "text": plainText(t).clip(600)
    }
    if not p.parent.isNil:
      item["replying_to"] = %*{"author": p.parent.user.username,
                               "text": plainText(p.parent).clip(250)}
    if t.quote.isSome and not t.quote.get.isNil:
      let q = t.quote.get
      item["quoting"] = %*{"author": q.user.username, "text": plainText(q).clip(250)}
    items.add item
  %*{"user": {"username": user.username, "name": user.fullname,
              "bio": stripHtml(user.bio).clip(300)},
     "posts": items}

proc buildSummary(user: User; posts: seq[Post]; parsed: JsonNode): JsonNode =
  var topics = newJArray()
  for tp in parsed{"topics"}.getElems():
    let name = tp{"name"}.getStr().strip()
    if name.len == 0: continue
    let line = tp{"line"}.getStr().strip()
    if line.len == 0: continue
    topics.add %*{"name": name, "line": line}
  if topics.len == 0:
    raise newException(ValueError, "LLM returned no topics")
  %*{
    "username": user.username,
    "overview": parsed{"overview"}.getStr().strip(),
    "topics": topics,
    "tweets": posts.len,
    "from": posts[^1].tweet.time.utc.format("yyyy-MM-dd"),
    "to": posts[0].tweet.time.utc.format("yyyy-MM-dd"),
    "days": sumOpts.days,
    "model": sumOpts.provider.model,
    "createdAt": nowIso()
  }

proc runSummary(run: SumRun) {.async.} =
  let key = run.username.toLowerAscii()
  try:
    let user = await getCachedUser(run.username)
    if user.id.len == 0: raise newException(ValueError, "User not found")
    if user.suspended: raise newException(ValueError, "This account is suspended")
    let posts = await collect(run, user)
    if posts.len == 0:
      raise newException(ValueError, "No posts, quotes or replies in the last " &
        $sumOpts.days & " days" & (if user.protected: " (the account is protected)" else: ""))
    run.stage = 1
    echo "[xtime] summary @", run.username, ": summarizing ", posts.len, " posts"
    let p = sumOpts.provider
    let parsed = await callLlmChat(p.model, p.baseUrl, p.apiKeyEnv,
      summaryPrompt, $promptInput(user, posts), p.timeoutMs, p.reasoningEffort)
    sumStore.setUserSummary(key, $buildSummary(user, posts, parsed))
    runs.del key
    echo "[xtime] summary @", run.username, ": done in ", epochMs() - run.startedAt, "ms"
  except CatchableError as e:
    run.status = "error"
    run.error = cleanError(e.msg)
    echo "[xtime] summary @", run.username, " failed: ", run.error

proc runJson(run: SumRun): JsonNode =
  %*{"status": run.status, "stage": run.stage, "fetched": run.fetched,
     "error": run.error, "elapsedMs": epochMs() - run.startedAt}

proc summaryJson*(username: string; refresh = false): JsonNode =
  ## The cached summary, the running/failed run, or a newly started run when
  ## there is neither or refresh asks for a new one.
  let key = username.toLowerAscii()
  let run = runs.getOrDefault(key)
  if not run.isNil and run.status == "running":
    return runJson(run)
  if not refresh:
    let cached = sumStore.getUserSummary(key)
    if not run.isNil:
      # a failed refresh keeps showing the previous summary alongside the error
      result = runJson(run)
      if cached.len > 0: result["summary"] = parseJson(cached)
      return
    if cached.len > 0:
      return %*{"status": "done", "summary": parseJson(cached)}
  let fresh = SumRun(username: username, status: "running", startedAt: epochMs())
  runs[key] = fresh
  asyncCheck runSummary(fresh)
  runJson(fresh)
