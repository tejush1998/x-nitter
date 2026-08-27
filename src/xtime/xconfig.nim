# x-time config: xtime.config.json + .env loading
import std/[json, os, strutils]

type
  LlmProvider* = object
    name*: string
    model*: string
    baseUrl*: string
    apiKeyEnv*: string
    timeoutMs*: int

  ClassifyOpts* = object
    model*: string
    baseUrl*: string
    apiKeyEnv*: string
    timeoutMs*: int
    topics*: seq[string]
    maxTopics*: int

  TranslateOpts* = object
    enabled*: bool
    model*: string
    baseUrl*: string
    apiKeyEnv*: string
    timeoutMs*: int

  XTimeConf* = object
    topics*: seq[string]
    maxTopics*: int
    pages*: int
    countPerPage*: int
    minPollIntervalSec*: int
    linkBase*: string
    classify*: ClassifyOpts
    translate*: TranslateOpts

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
    raise newException(ValueError, "config.json: unknown provider \"" & name & "\"")
  LlmProvider(
    name: name,
    model: providers{name}{"model"}.getStr(),
    baseUrl: providers{name}{"baseUrl"}.getStr(),
    apiKeyEnv: providers{name}{"apiKeyEnv"}.getStr(),
    timeoutMs: providers{name}{"timeoutMs"}.getInt(60000)
  )

proc optInt(node: JsonNode, key: string, default: int): int =
  if node != nil and not node{key}.isNil and node{key}.kind == JInt:
    node{key}.getInt()
  else:
    default

proc loadXTimeConf*(path = "xtime.config.json"): XTimeConf =
  let raw = json.parseFile(path)
  var topics: seq[string] = @[]
  if raw{"topics"} != nil:
    for t in raw{"topics"}:
      let s = t.getStr().strip()
      if s.len > 0: topics.add s

  let c = raw{"classify"}
  let providerName = c{"provider"}.getStr()
  if providerName.len == 0:
    raise newException(ValueError, "config.json: classify.provider is not set")
  let cp = parseProvider(raw{"providers"}, providerName)

  let t = raw{"translate"}
  let tp = parseProvider(raw{"providers"}, t{"provider"}.getStr())

  result = XTimeConf(
    topics: topics,
    maxTopics: raw{"maxTopics"}.getInt(20),
    pages: raw{"pages"}.getInt(3),
    countPerPage: raw{"countPerPage"}.getInt(20),
    minPollIntervalSec: raw{"minPollIntervalSec"}.getInt(60),
    linkBase: raw{"linkBase"}.getStr("http://localhost:8080"),
    classify: ClassifyOpts(
      model: cp.model,
      baseUrl: cp.baseUrl,
      apiKeyEnv: cp.apiKeyEnv,
      timeoutMs: cp.timeoutMs,
      topics: topics,
      maxTopics: raw{"maxTopics"}.getInt(20)
    ),
    translate: TranslateOpts(
      enabled: if t{"enabled"}.isNil: true else: t{"enabled"}.getBool(),
      model: tp.model,
      baseUrl: tp.baseUrl,
      apiKeyEnv: tp.apiKeyEnv,
      timeoutMs: tp.timeoutMs
    )
  )
