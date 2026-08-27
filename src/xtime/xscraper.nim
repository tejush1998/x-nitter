# x-time X API layer: subprocess calls into scraper.py (twifork/twikit).
# Native Nim HTTPS only for the auth check (settings.json) — x.com
# soft-blocks Nim's TLS fingerprint on graphql endpoints.
import std/[json, asyncfutures, asyncdispatch, httpclient, strutils, os, uri, osproc]
import zippy
import ../consts
import ../tid
import ./xstore

type
  XCredentials* = object
    authToken*: string
    ct0*: string

  XAuthError* = object of CatchableError
  XActionError* = object of CatchableError
  XNotFoundError* = object of CatchableError

  UserInfo* = object
    userId*: string
    username*: string
    following*: bool

const userAgentVal = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"

# nil-safe JSON navigation
proc jget*(n: JsonNode, key: string): JsonNode =
  if n.isNil: nil else: n{key}

proc jget*(n: JsonNode, idx: int): JsonNode =
  if n.isNil or n.kind != JArray or idx < 0 or idx >= n.len: nil else: n[idx]

proc jstr*(n: JsonNode, default = ""): string =
  if n.isNil or n.kind != JString: default else: n.getStr()

proc jint*(n: JsonNode, default = 0): int =
  if n.isNil: default
  elif n.kind == JInt: n.getInt()
  elif n.kind == JString:
    try: parseInt(n.getStr()) except: default
  else: default

proc jbool*(n: JsonNode, default = false): bool =
  if n.isNil or n.kind != JBool: default else: n.getBool()

# ---------------------------------------------------------------- cookies

proc loadCredentials*(): XCredentials =
  result.authToken = getEnv("AUTH_TOKEN")
  result.ct0 = getEnv("CT0")
  if result.authToken.len > 0 and result.ct0.len > 0: return
  let path = "cookies.json"
  if not fileExists(path):
    raise newException(XAuthError,
      "No cookies: set AUTH_TOKEN + CT0 env vars or create cookies.json")
  let raw = parseFile(path)
  case raw.kind
  of JObject:
    if result.authToken.len == 0:
      result.authToken = jget(raw, "auth_token").jstr()
    if result.ct0.len == 0:
      result.ct0 = jget(raw, "ct0").jstr()
  of JArray:
    for item in raw:
      let name = jget(item, "name").jstr()
      let value = jget(item, "value").jstr()
      case name
      of "auth_token":
        if result.authToken.len == 0: result.authToken = value
      of "ct0":
        if result.ct0.len == 0: result.ct0 = value
      else: discard
  else:
    raise newException(XAuthError, "cookies.json: unexpected format")
  if result.authToken.len == 0 or result.ct0.len == 0:
    raise newException(XAuthError, "cookies.json: missing auth_token or ct0")

# ---------------------------------------------------------------- native auth check

proc genXHeaders*(cred: XCredentials, isForm: bool,
    legacyBearer: bool, urlPath: string,
    sendTid = false): Future[HttpHeaders] {.async.} =
  var pairs = @[
    ("accept", "*/*"),
    ("accept-encoding", "gzip, deflate"),
    ("accept-language", "en-US,en;q=0.9"),
    ("origin", "https://x.com"),
    ("user-agent", userAgentVal),
    ("x-twitter-active-user", "yes"),
    ("x-twitter-client-language", "en"),
    ("priority", "u=1, i"),
    ("x-twitter-auth-type", "OAuth2Session"),
    ("x-csrf-token", cred.ct0),
    ("cookie", "auth_token=" & cred.authToken & "; ct0=" & cred.ct0),
    ("referer", "https://x.com/"),
    ("sec-ch-ua", """"Google Chrome";v="142", "Chromium";v="142", "Not A(Brand";v="24""""),
    ("sec-ch-ua-mobile", "?0"),
    ("sec-ch-ua-platform", "Windows"),
    ("sec-fetch-dest", "empty"),
    ("sec-fetch-mode", "cors"),
    ("sec-fetch-site", "same-origin"),
    ("authorization", if legacyBearer: bearerToken2 else: bearerToken)
  ]
  if isForm:
    pairs.add(("content-type", "application/x-www-form-urlencoded"))
  else:
    pairs.add(("content-type", "application/json"))
  result = newHttpHeaders(pairs, titleCase = true)
  if sendTid:
    result["x-client-transaction-id"] = await genTid(urlPath)

proc clip(s: string, n: int): string =
  if s.len > n: s[0 ..< n] else: s

proc xRequest(meth: HttpMethod, url: string, cred: XCredentials,
    body = "", isForm = false, legacyBearer = false, sendTid = false,
    timeoutMs = 30000): Future[tuple[status: int, text: string]] {.async.} =
  let headers = await genXHeaders(cred, isForm, legacyBearer,
    parseUri(url).path, sendTid)
  let client = newAsyncHttpClient(userAgent = "", headers = headers,
    maxRedirects = 0)
  try:
    let reqFut = client.request(url, meth, body)
    var resp: AsyncResponse
    if not await withTimeout(reqFut, timeoutMs):
      raise newException(XActionError, "X API timeout after " & $timeoutMs & "ms")
    resp = reqFut.read()
    let bodyFut = resp.body
    var text: string
    if not await withTimeout(bodyFut, timeoutMs):
      raise newException(XActionError, "X API timeout reading response body")
    text = bodyFut.read()
    # Nim doesn't auto-decompress when we set Accept-Encoding ourselves
    if resp.headers.getOrDefault("content-encoding") == "gzip" and text.len >= 2:
      try: text = zippy.uncompress(text, dfGzip)
      except: discard
    result = (resp.code.int, text)
  finally:
    try: client.close()
    except: discard

proc verifyCredentials*(cred: XCredentials) {.async.} =
  ## Raises XAuthError if cookies are expired/invalid.
  ## (verify_credentials.json is retired; settings.json works but requires tid)
  let (status, text) = await xRequest(HttpGet,
    "https://x.com/i/api/1.1/account/settings.json", cred, sendTid = true)
  if status == 401 or status == 403:
    raise newException(XAuthError,
      "Cookies are expired or invalid. Re-export auth_token + ct0 from your browser.")
  if status != 200:
    raise newException(XActionError,
      "Auth check failed (" & $status & ": " & clip(text, 200) & ")")

# ---------------------------------------------------------------- python subprocess

var pyCounter = 0

proc pythonBin(): string =
  if fileExists(".venv/bin/python"): ".venv/bin/python" else: "python3"

proc runPython*(args: seq[string]): Future[JsonNode] {.async.} =
  ## Run scraper.py with the given flags; result JSON via --out file,
  ## stderr captured to XN_ERRFILE for error messages.
  pyCounter.inc
  let base = getTempDir() & "xn_" & $epochMs() & "_" & $pyCounter
  let outPath = base & ".json"
  let errPath = base & ".err"
  putEnv("XN_ERRFILE", errPath)
  let p = startProcess(pythonBin(),
    args = @["scraper.py"] & args & @["--out", outPath],
    options = {poStdErrToStdOut, poUsePath})
  var code = -1
  while true:
    code = p.peekExitCode()
    if code != -1: break
    await sleepAsync(60)
  var text = ""
  if fileExists(outPath):
    try: text = readFile(outPath)
    except: discard
  var errMsg = ""
  if fileExists(errPath):
    try: errMsg = readFile(errPath).strip()
    except: discard
  try: removeFile(outPath)
  except: discard
  try: removeFile(errPath)
  except: discard
  try: p.close()
  except: discard

  if code == 2:
    raise newException(XAuthError, if errMsg.len > 0: errMsg else:
      "X cookies are missing or invalid (set AUTH_TOKEN + CT0 or cookies.json)")
  if code != 0:
    var msg = if errMsg.len > 0: errMsg else:
      "scraper.py failed with exit code " & $code
    if msg.contains("not found on X"):
      raise newException(XNotFoundError, msg)
    raise newException(XActionError, msg)
  if text.len == 0:
    raise newException(XActionError,
      if errMsg.len > 0: errMsg else: "scraper.py produced no output")
  return parseJson(text)

# ---------------------------------------------------------------- public API (subprocess)

proc fetchHomeTimeline*(cred: XCredentials, count: int, pages: int,
    seen: seq[string]): Future[seq[Tweet]] {.async.} =
  ## Home timeline via scraper.py (twifork impersonated client).
  var args = @["--cookies", "cookies.json", "--count", $count,
               "--pages", $max(1, pages)]
  if seen.len > 0:
    args.add @["--seen", seen.join(",")]
  let j = await runPython(args)
  if j.kind != JArray:
    raise newException(XActionError, "scraper.py: unexpected output shape")
  for item in j:
    var links: seq[string] = @[]
    case jget(item, "links").kind
    of JArray:
      for u in jget(item, "links"):
        if u.kind == JString: links.add u.getStr()
    of JString:
      let parsed = jget(item, "links").getStr()
      if parsed.len > 2:
        try:
          let arr = parseJson(parsed)
          for u in arr: links.add u.getStr()
        except: discard
    else: discard
    var media: seq[string] = @[]
    case jget(item, "media").kind
    of JArray:
      for m in jget(item, "media"):
        if m.kind == JString: media.add m.getStr()
    of JString:
      let parsed = jget(item, "media").getStr()
      if parsed.len > 2:
        try:
          let arr = parseJson(parsed)
          for m in arr: media.add m.getStr()
        except: discard
    else: discard
    result.add Tweet(
      id: jget(item, "id").jstr(),
      text: jget(item, "text").jstr(),
      authorId: jget(item, "author_id").jstr(),
      authorName: jget(item, "author_name").jstr(),
      authorUsername: jget(item, "author_username").jstr(),
      createdAt: jget(item, "created_at").jstr(),
      likeCount: jget(item, "like_count").jint(0),
      retweetCount: jget(item, "retweet_count").jint(0),
      replyCount: jget(item, "reply_count").jint(0),
      viewCount: jget(item, "view_count").jint(0),
      links: links,
      media: media,
      promoted: jget(item, "promoted").jstr() in ["True", "true", "1"],
      raw: jget(item, "raw").jstr()
    )

proc favoriteTweet*(cred: XCredentials, tweetId: string, unlike: bool) {.async.} =
  var args = @["--like", tweetId]
  if unlike: args.add "--unlike"
  discard await runPython(args)

proc userByScreenName*(cred: XCredentials, username: string): Future[UserInfo] {.async.} =
  ## Following-check via scraper.py (--following).
  let j = await runPython(@["--following", username])
  if jget(j, "ok").jbool(false):
    return UserInfo(
      userId: jget(j, "user_id").jstr(),
      username: jget(j, "username").jstr(username),
      following: jget(j, "following").jbool(false))
  raise newException(XActionError, "User lookup failed for @" & username)

proc followUser*(cred: XCredentials, username: string,
    unfollow: bool): Future[UserInfo] {.async.} =
  ## Follow/unfollow via scraper.py; returns resulting following state.
  let j = await runPython(@[(if unfollow: "--unfollow" else: "--follow"), username])
  if jget(j, "ok").jbool(false):
    return UserInfo(
      userId: jget(j, "user_id").jstr(),
      username: jget(j, "username").jstr(username),
      following: (if unfollow: false else: true))
  raise newException(XActionError,
    (if unfollow: "Unfollow failed for @" else: "Follow failed for @") & username)
