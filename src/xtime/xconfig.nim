# x-time config: xtime.config.json + .env loading
import std/[json, os, strutils]

type
  LlmProvider* = object
    name*: string
    model*: string
    baseUrl*: string
    apiKeyEnv*: string
    timeoutMs*: int
    reasoningEffort*: string  # sent as reasoning_effort when set, e.g. "low"

  ClassifyOpts* = object
    model*: string
    baseUrl*: string
    apiKeyEnv*: string
    timeoutMs*: int
    reasoningEffort*: string
    topics*: seq[string]
    maxTopics*: int
    chunkSize*: int         # tweets per call; 0 sends the whole batch in one
    chunkConcurrency*: int

  TranslateOpts* = object
    enabled*: bool
    model*: string
    baseUrl*: string
    apiKeyEnv*: string
    timeoutMs*: int
    reasoningEffort*: string
    providers*: seq[LlmProvider]  # live page translation: provider, then fallbacks in order

  RecommendOpts* = object
    providers*: seq[LlmProvider]  # tried in order until one answers
    replySample*: int
    picks*: int
    days*: int                    # look-back window before the viewed tweet

  SummaryOpts* = object
    provider*: LlmProvider        # no fallback
    days*: int                    # look-back window
    maxTweets*: int
    maxPages*: int                # Replies-tab pages (about 20 posts each)

  XTimeConf* = object
    topics*: seq[string]
    maxTopics*: int
    pages*: int
    countPerPage*: int
    minPollIntervalSec*: int
    classify*: ClassifyOpts
    translate*: TranslateOpts
    recommend*: RecommendOpts
    summary*: SummaryOpts

proc loadDotEnv*(path = ".env") =
  ## Minimal .env loader: KEY=VALUE lines, does not override existing env.
  if not fileExists(path): return
  for rawLine in lines(path):
    var line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"): continue
    if line.startsWith("export "): line = line[7 .. ^1].strip()
    let eq = line.find('=')
    if eq <= 0: continue
    var key = line[0 ..< eq].strip()
    var val = line[(eq+1) ..< line.len].strip()
    if val.len >= 2 and ((val[0] == '"' and val[^1] == '"') or (val[0] == '\'' and val[^1] == '\'')):
      val = val[1 ..< ^1]
    if getEnv(key).len == 0:
      putEnv(key, val)

proc parseProvider(providers: JsonNode, name: string): LlmProvider =
  if providers.isNil or providers{name}.isNil:
    raise newException(ValueError, "xtime.config.json: unknown provider \"" & name & "\"")
  LlmProvider(
    name: name,
    model: providers{name}{"model"}.getStr(),
    baseUrl: providers{name}{"baseUrl"}.getStr(),
    apiKeyEnv: providers{name}{"apiKeyEnv"}.getStr(),
    timeoutMs: providers{name}{"timeoutMs"}.getInt(60000),
    reasoningEffort: providers{name}{"reasoningEffort"}.getStr()
  )

proc optInt(node: JsonNode, key: string, default: int): int =
  if node != nil and not node{key}.isNil and node{key}.kind == JInt:
    node{key}.getInt()
  else:
    default

proc loadXTimeConf*(path = "xtime.config.json"): XTimeConf =
  ## Accepts // and /* */ comments, as std/json's parser does.
  let raw = json.parseFile(path)
  var topics: seq[string] = @[]
  if raw{"topics"} != nil:
    for t in raw{"topics"}:
      let s = t.getStr().strip()
      if s.len > 0: topics.add s

  let providerName = raw{"provider"}.getStr()
  if providerName.len == 0:
    raise newException(ValueError, "xtime.config.json: provider is not set")
  let p = parseProvider(raw{"providers"}, providerName)
  # translation and recommendations try the fallbacks in order after provider
  var withFallback = @[p]
  for f in raw{"fallback"}.getElems():
    withFallback.add parseProvider(raw{"providers"}, f.getStr())

  let maxTopics = raw{"maxTopics"}.getInt(20)
  let r = raw{"recommend"}
  let s = raw{"summary"}
  XTimeConf(
    topics: topics,
    maxTopics: maxTopics,
    pages: raw{"pages"}.getInt(3),
    countPerPage: 20,
    minPollIntervalSec: 60,
    classify: ClassifyOpts(
      model: p.model,
      baseUrl: p.baseUrl,
      apiKeyEnv: p.apiKeyEnv,
      timeoutMs: p.timeoutMs,
      reasoningEffort: p.reasoningEffort,
      topics: topics,
      maxTopics: maxTopics,
      chunkSize: 20,
      chunkConcurrency: 3
    ),
    translate: TranslateOpts(
      enabled: raw{"translate"}.getBool(true),
      model: p.model,
      baseUrl: p.baseUrl,
      apiKeyEnv: p.apiKeyEnv,
      timeoutMs: p.timeoutMs,
      reasoningEffort: p.reasoningEffort,
      providers: withFallback
    ),
    recommend: RecommendOpts(
      providers: withFallback,
      replySample: optInt(r, "replySample", 8),
      picks: optInt(r, "picks", 4),
      days: optInt(r, "days", 14)
    ),
    summary: SummaryOpts(
      provider: p,
      days: optInt(s, "days", 14),
      maxTweets: optInt(s, "maxTweets", 100),
      maxPages: optInt(s, "maxPages", 10)
    )
  )
