# x-time LLM calls: OpenAI-compatible chat/completions over HTTPS
# Single-pass classification + translation (no fallbacks, no chunking)
import std/[json, asyncfutures, asyncdispatch, httpclient, strutils, os, options, tables]
import zippy
import ./xstore
import ./xconfig
import ./xstatus

type
  LLMTimeoutError* = object of CatchableError
  LLMHttpError* = object of CatchableError
    status*: int
    respBody*: string

proc postJson*(url: string, apiKey: string, body: string,
    timeoutMs: int): Future[tuple[status: int, text: string]] {.async.} =
  ## POST JSON with Bearer auth; raises LLMTimeoutError on timeout.
  var headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Accept": "application/json",
    "Accept-Encoding": "gzip, deflate",
    "Connection": "keep-alive"
  })
  if apiKey.len > 0:
    headers.add("Authorization", "Bearer " & apiKey)
  let client = newAsyncHttpClient(userAgent = "", headers = headers)
  try:
    let reqFut = client.request(url, HttpPost, body)
    var resp: AsyncResponse
    if not await withTimeout(reqFut, timeoutMs):
      raise newException(LLMTimeoutError,
        "LLM API timeout after " & $timeoutMs & "ms")
    resp = reqFut.read()
    let bodyFut = resp.body
    var text: string
    if not await withTimeout(bodyFut, timeoutMs):
      raise newException(LLMTimeoutError,
        "LLM API timeout after " & $timeoutMs & "ms reading response body")
    text = bodyFut.read()
    # Nim doesn't auto-decompress when we set Accept-Encoding ourselves
    if resp.headers.getOrDefault("content-encoding") == "gzip" and text.len >= 2:
      try: text = zippy.uncompress(text, dfGzip)
      except: discard
    result = (resp.code.int, text)
  finally:
    try: client.close()
    except: discard

proc parseJsonContent*(content: string): JsonNode =
  ## Parse LLM JSON output; tolerate ```json fences.
  var s = content.strip()
  if s.startsWith("```"):
    var nl = s.find('\n')
    if nl >= 0: s = s[(nl+1) .. ^1]
    if s.strip().endsWith("```"):
      s = s.strip()[0 ..< ^3]
    s = s.strip()
  if s.len == 0:
    raise newException(ValueError, "LLM returned empty JSON content")
  try:
    return parseJson(s)
  except:
    let start = s.find('{')
    let finish = s.rfind('}')
    if start >= 0 and finish > start:
      return parseJson(s[start .. finish])
    raise

proc langOf*(s: string): string =
  ## lowercase ISO-639-1/2 code or ""
  let v = s.strip().toLowerAscii()
  if v.len < 2 or v.len > 3: return ""
  for c in v:
    if c notin {'a'..'z'}: return ""
  return v

proc chatCompletionsBody*(model: string, systemPrompt: string,
    userContent: string): JsonNode =
  %*{
    "model": model,
    "temperature": 0,
    "response_format": {"type": "json_object"},
    "messages": [
      {"role": "system", "content": systemPrompt},
      {"role": "user", "content": userContent}
    ]
  }

proc callLlmChat*(model: string, baseUrl: string, apiKeyEnv: string,
    systemPrompt: string, userContent: string,
    timeoutMs: int): Future[JsonNode] {.async.} =
  ## One chat/completions call; returns parsed content JSON or raises.
  let apiKey = if apiKeyEnv.len > 0: getEnv(apiKeyEnv) else: ""
  let url = baseUrl.strip(leading = false, trailing = true, {'/'}) & "/chat/completions"
  let body = $chatCompletionsBody(model, systemPrompt, userContent)
  let (status, text) = await postJson(url, apiKey, body, timeoutMs)
  if status < 200 or status >= 300:
    var hint = text
    if hint.len > 300: hint = hint[0 ..< 300]
    raise newException(LLMHttpError,
      "LLM API error " & $status &
      " (hint 401 invalid key / 429 rate limit): " & hint)
  let respJson = parseJson(text)
  let content = respJson{"choices"}{0}{"message"}{"content"}
  if content.isNil or content.kind != JString or content.getStr().len == 0:
    raise newException(ValueError,
      "LLM API returned no content (model: " & model & ")")
  return parseJsonContent(content.getStr())

# ---------------------------------------------------------------- classify

proc buildClassifySystemPrompt*(topics: seq[string], maxTopics: int): string =
  var lines: seq[string] = @[
    "You classify tweets by assigning exactly ONE topic per tweet.",
    "Topics must be specific and mutually exclusive."
  ]
  if topics.len > 0:
    var parts: seq[string] = @[]
    for t in topics: parts.add("\"" & t & "\"")
    lines.add("Allowed topics: " & parts.join(", ") & ".")
  else:
    lines.add("Invent topics on the fly, preferring short named nouns " &
      "(examples: \"Anthropic\", \"DeepSeek\", \"portfolio allocation\", " &
      "\"drone news\", \"personal ramblings\"). " &
      "Reuse the same topic name for tweets about the same subject. " &
      "Use \"other\" only as a fallback.")
  if maxTopics > 0:
    lines.add("Use AT MOST " & $maxTopics & " distinct topic names.")
  lines.add("""Mark noise=true for: ads, memes, engagement bait, motivational quotes, off-topic posts, shoutouts, low-effort replies; pure negativity without a solution, alternative, or takeaway; heavy personal opinion with low insight, UNLESS it contains a generalizable insight.
Facts, mechanics, comparisons, data, reasoning, or a concrete takeaway are NOT noise.
When in doubt, prefer noise=true. Noisy tweets still get the most accurate topic.
confidence is 0..1. lang is the tweet language as a lowercase ISO 639-1 code ("en" for mostly English).""")
  lines.add("""Respond with JSON only, no commentary, in exactly this shape:
{"results":[{"tweet_id":"...","topic":"...","noise":false,"confidence":0.8,"lang":"en"}]}
Include exactly one result per input tweet, using the same tweet_id values.""")
  lines.join("\n")

proc buildClassifyUserContent*(tweets: seq[Tweet]): string =
  var items: seq[JsonNode] = @[]
  for tw in tweets:
    var text = tw.text
    if text.len > 500: text = text[0 ..< 500]
    items.add %*{
      "id": tw.id,
      "author": "@" & tw.authorUsername,
      "text": text,
      "has_links": tw.links.len > 0,
      "has_media": tw.media.len > 0
    }
  $(%*{"tweets": items})

proc classifyTweets*(tweets: seq[Tweet], opts: ClassifyOpts): Future[seq[Assignment]] {.async.} =
  ## Single-pass classification: one LLM call for the whole batch.
  if tweets.len == 0: return @[]
  setClassifyPhase("classifying", tweets.len, "classifying " & $tweets.len & " tweets")
  setClassifyAttempt(CurrentAttempt(
    label: "primary", model: opts.model, baseUrl: opts.baseUrl,
    timeoutMs: opts.timeoutMs, chunk: 0, chunks: 1))
  let systemPrompt = buildClassifySystemPrompt(opts.topics, opts.maxTopics)
  let userContent = buildClassifyUserContent(tweets)
  let parsed = await callLlmChat(
    opts.model, opts.baseUrl, opts.apiKeyEnv, systemPrompt, userContent, opts.timeoutMs)

  var byId: Table[string, bool]
  for tw in tweets: byId[tw.id] = true
  var count = 0
  if parsed{"results"} != nil and parsed{"results"}.kind == JArray:
    for r in parsed{"results"}:
      let id = r{"tweet_id"}.getStr()
      if not byId.getOrDefault(id, false): continue
      var conf: Option[float] = none(float)
      if r{"confidence"} != nil and r{"confidence"}.kind == JFloat:
        conf = some(r{"confidence"}.getFloat())
      elif r{"confidence"} != nil and r{"confidence"}.kind == JInt:
        conf = some(r{"confidence"}.getInt().float)
      result.add Assignment(
        tweetId: id,
        topic: (if r{"topic"} != nil and r{"topic"}.kind == JString and
          r{"topic"}.getStr().len > 0: r{"topic"}.getStr() else: "other"),
        noise: r{"noise"} != nil and r{"noise"}.getBool(),
        confidence: conf,
        lang: langOf(r{"lang"}.getStr())
      )
      count.inc
  addClassifyProgress(count)

# ---------------------------------------------------------------- translate

proc buildTranslateSystemPrompt*(): string =
  """Translate each tweet into natural, fluent English.
Keep the original tone. Do not add interpretation or commentary.
Preserve @handles, #hashtags, $cashtags, URLs, numbers, and quoted speech exactly.
Keep names as-is. If a tweet is already in English, return it unchanged.
Respond with JSON only, in exactly this shape:
{"results":[{"tweet_id":"...","translation":"..."}]}
Include exactly one result per input tweet, using the same tweet_id values."""

proc buildTranslateUserContent*(tweets: seq[Tweet]): string =
  var items: seq[JsonNode] = @[]
  for tw in tweets:
    items.add %*{"id": tw.id, "text": tw.text.strip()}
  $(%*{"tweets": items})

proc translateTweets*(tweets: seq[Tweet], opts: TranslateOpts): Future[seq[(string, string)]] {.async.} =
  ## One LLM call translating all given tweets to English.
  if tweets.len == 0: return @[]
  setClassifyPhase("translating", tweets.len,
    "translating " & $tweets.len & " non-English tweets")
  setClassifyAttempt(CurrentAttempt(
    label: "primary", model: opts.model, baseUrl: opts.baseUrl,
    timeoutMs: opts.timeoutMs, chunk: 0, chunks: 1))
  let parsed = await callLlmChat(
    opts.model, opts.baseUrl, opts.apiKeyEnv,
    buildTranslateSystemPrompt(), buildTranslateUserContent(tweets), opts.timeoutMs)
  var byId: Table[string, bool]
  for tw in tweets: byId[tw.id] = true
  var count = 0
  if parsed{"results"} != nil and parsed{"results"}.kind == JArray:
    for r in parsed{"results"}:
      let id = r{"tweet_id"}.getStr()
      let tr = r{"translation"}.getStr().strip()
      if not byId.getOrDefault(id, false) or tr.len == 0: continue
      result.add (id, tr)
      count.inc
  addClassifyProgress(count)
