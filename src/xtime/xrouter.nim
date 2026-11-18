# x-time jester router: UI + API (replaces server.js; CORS hack removed)
import std/[json, strutils, asyncdispatch, options, os]
import jester
import xconfig, xstore, xscraper, xstatus, xengine, xjobs, xrecommend, xpeople, xsummary, xtranslate
import ../routes/router_utils

# Re-export what nitter.nim needs, but NOT xstore.Tweet / Assignment
# (clashes with types.Tweet inside jester's routes macro expansion).
export xconfig, xjobs, xengine, xscraper, xstatus, xrecommend, xpeople, xsummary, xtranslate
export xstore except Tweet, Assignment

var
  xtimeStore*: XStore = nil
  xtimeConf*: XTimeConf

const recommendMetaKey* = "experiment.recommend"

proc experimentsJson*(): JsonNode =
  %*{"recommend": recommendEnabled()}

proc createXTimeRouter*(store: XStore, conf: XTimeConf) =
  xtimeStore = store
  xtimeConf = conf
  initRecommend(conf.recommend, store.getMeta(recommendMetaKey) == "1")
  initSummary(conf.summary, store)
  initTranslate(conf.translate, store)
  router xtime:

    get "/xtime":
      redirect("/xtime/")

    get "/xtime/":
      let path = "public/xtime/index.html"
      if fileExists(path):
        resp readFile(path), "text/html;charset=utf-8"
      else:
        resp Http404, "xtime UI not found"

    get "/api/snapshot":
      let noise = @"noise" == "1"
      let liked = @"liked" == "1"
      let batch = @"batch"
      respJson getFeedSnapshot(xtimeStore, xtimeConf, noise, batch, liked)

    get "/api/nouns":
      let noise = @"noise" == "1"
      let liked = @"liked" == "1"
      let batch = @"batch"
      let noun = @"noun".strip().toLowerAscii()
      if noun.len == 0:
        respJson %*{"noun": "", "tweets": []}
      else:
        let tweets = xtimeStore.getTweetsByNoun(noun, 50, noise, batch, liked)
        respJson %*{"noun": noun, "tweets": tweetsJson(tweets)}

    get "/api/status":
      var active: JsonNode = newJNull()
      let curJob = getActiveJob()
      if not curJob.isNil:
        active = jobToJson(curJob)
      var history = newJArray()
      for j in getJobHistory():
        history.add jobToJson(j)
      respJson %*{
        "active": active,
        "classify": statusJson(classifyStatus()),
        "history": history
      }

    post "/api/scrape":
      try:
        let activeJob = getActiveJob()
        let remaining = pollTooSoonNow(xtimeStore, xtimeConf.minPollIntervalSec)
        if not activeJob.isNil and activeJob.status == "running":
          resp Http409, @[("Content-Type", "application/json")], $ %*{
            "error": "Another job is already running",
            "active": jobToJson(activeJob)
          }
        elif remaining.isSome:
          resp Http429, @[("Content-Type", "application/json")], $ %*{
            "error": "Poll too soon; last poll " & $xtimeConf.minPollIntervalSec &
              "s interval, retry in " & $remaining.get & "s",
            "retryInSec": remaining.get
          }
        else:
          let scrapeCount = if @"count".len > 0: parseInt(@"count")
                            else: xtimeConf.countPerPage
          let scrapePages = if @"pages".len > 0: parseInt(@"pages")
                            else: xtimeConf.pages
          let job = startJob("scrape", "scrape") do() -> Future[JsonNode] {.async.}:
            await scrapePoll(xtimeStore, xtimeConf, scrapeCount, scrapePages, "scrape")
          resp Http202, @[("Content-Type", "application/json")], $ %*{"jobId": job.id}
      except JobBusyError as e:
        resp Http409, @[("Content-Type", "application/json")], $ %*{
          "error": e.msg, "active": e.activeId
        }
      except CatchableError as e:
        resp Http500, @[("Content-Type", "application/json")], $ %*{"error": e.msg}

    post "/api/reclassify":
      try:
        var body = newJObject()
        try:
          if request.body.len > 0: body = parseJson(request.body)
        except: discard
        let batch = body{"batch"}.getStr("")
        let job = startJob("reclassify", "reclassify") do() -> Future[JsonNode] {.async.}:
          await classifyStored(xtimeStore, xtimeConf, batch)
        resp Http202, @[("Content-Type", "application/json")], $ %*{"jobId": job.id}
      except JobBusyError as e:
        resp Http409, @[("Content-Type", "application/json")], $ %*{
          "error": e.msg, "active": e.activeId
        }
      except CatchableError as e:
        resp Http500, @[("Content-Type", "application/json")], $ %*{"error": e.msg}

    post "/api/like":
      try:
        let body = parseJson(request.body)
        let tweetId = body{"tweetId"}.getStr()
        let unlike = (if body{"unlike"}.isNil: false else: body{"unlike"}.getBool())
        if tweetId.len == 0:
          resp Http400, @[("Content-Type", "application/json")], $ %*{"error": "tweetId is required"}
        else:
          let cred = loadCredentials()
          await favoriteTweet(cred, tweetId, unlike)
          xtimeStore.setTweetLiked(tweetId, not unlike)
          respJson %*{
            "ok": true,
            "status": (if unlike: "unliked" else: "liked"),
            "tweetId": tweetId
          }
      except XAuthError as e:
        resp Http502, @[("Content-Type", "application/json")], $ %*{"error": e.msg}
      except CatchableError as e:
        resp Http500, @[("Content-Type", "application/json")], $ %*{"error": e.msg}

    post "/api/follow":
      try:
        let body = parseJson(request.body)
        let username = body{"username"}.getStr().strip(chars = {'@', ' '})
        let unfollow = (if body{"unfollow"}.isNil: false else: body{"unfollow"}.getBool())
        if username.len == 0:
          resp Http400, @[("Content-Type", "application/json")], $ %*{"error": "username is required"}
        else:
          let cred = loadCredentials()
          let info = await followUser(cred, username, unfollow)
          respJson %*{"ok": true, "username": info.username, "following": info.following}
      except XNotFoundError as e:
        resp Http404, @[("Content-Type", "application/json")], $ %*{"error": e.msg}
      except XAuthError as e:
        resp Http502, @[("Content-Type", "application/json")], $ %*{"error": e.msg}
      except CatchableError as e:
        resp Http502, @[("Content-Type", "application/json")], $ %*{"error": e.msg}

    get "/api/following":
      try:
        let username = @"username".strip(chars = {'@'})
        if username.len == 0:
          resp Http400, @[("Content-Type", "application/json")], $ %*{"error": "username is required"}
        else:
          let cred = loadCredentials()
          let info = await userByScreenName(cred, username)
          respJson %*{"ok": true, "username": info.username, "following": info.following}
      except XNotFoundError as e:
        resp Http404, @[("Content-Type", "application/json")], $ %*{"error": e.msg}
      except XAuthError as e:
        resp Http502, @[("Content-Type", "application/json")], $ %*{"error": e.msg}
      except CatchableError as e:
        resp Http502, @[("Content-Type", "application/json")], $ %*{"error": e.msg}

    get "/api/people":
      # The dashboard's people search bar.
      let q = @"q".strip()
      if q.len == 0 or q.len > 100:
        resp Http400, @[("Content-Type", "application/json")], $ %*{"error": "q is required"}
      else:
        try:
          respJson %*{"ok": true, "people": await searchPeople(q)}
        except CatchableError as e:
          resp Http502, @[("Content-Type", "application/json")], $ %*{"error": e.msg}

    get "/api/people/recent":
      respJson %*{"ok": true, "people": recentPeople(xtimeStore)}

    post "/api/people/recent":
      # Someone opened from the dashboard's people search.
      try:
        let body = parseJson(request.body)
        if not validUsername(body{"username"}.getStr().strip(chars = {'@', ' '})):
          resp Http400, @[("Content-Type", "application/json")], $ %*{"error": "username is required"}
        else:
          respJson %*{"ok": true, "people": rememberPerson(xtimeStore, body)}
      except CatchableError as e:
        resp Http400, @[("Content-Type", "application/json")], $ %*{"error": e.msg}

    post "/api/people/forget":
      try:
        let username = parseJson(request.body){"username"}.getStr().strip(chars = {'@', ' '})
        if not validUsername(username):
          resp Http400, @[("Content-Type", "application/json")], $ %*{"error": "username is required"}
        else:
          respJson %*{"ok": true, "people": forgetPerson(xtimeStore, username)}
      except CatchableError as e:
        resp Http400, @[("Content-Type", "application/json")], $ %*{"error": e.msg}

    get "/api/recommend":
      # Polled by /js/recommend.js on tweet pages. Without start=1 or
      # refresh=1 it only reports an existing run ("idle" when there is none).
      let id = @"id"
      if id.len == 0 or id.len > 19 or not id.allCharsInSet(Digits):
        resp Http400, @[("Content-Type", "application/json")], $ %*{"error": "id is required"}
      elif not recommendEnabled():
        resp Http409, @[("Content-Type", "application/json")], $ %*{
          "error": "Recommendations are turned off (dashboard → Labs)", "disabled": true
        }
      else:
        let refresh = @"refresh" == "1"
        let run = if refresh or @"start" == "1":
                    ensureRecommend(id, refresh = refresh, retryFailed = true)
                  else: findRecommend(id)
        if run.isNil:
          respJson %*{"status": "idle"}
        else:
          respJson recommendJson(run, requestPrefs(), @"path")

    get "/api/summary":
      # Polled by /js/summary.js from a profile's ✦ button; starts a run if
      # there is no cached summary, or refresh=1 asks for a new one.
      let username = (@"username").strip(chars = {'@', ' '})
      if not validUsername(username):
        resp Http400, @[("Content-Type", "application/json")], $ %*{"error": "username is required"}
      else:
        respJson summaryJson(username, refresh = @"refresh" == "1")

    post "/api/translate":
      # Called by /js/translate.js with a page's non-English tweets and bio,
      # up to 20 per request; see xtranslate.nim for the body.
      var items: seq[TrItem]
      var bad = ""
      try:
        items = parseTrItems(request.body)
      except CatchableError as e:
        bad = e.msg
      if not translateEnabled():
        resp Http409, @[("Content-Type", "application/json")], $ %*{
          "error": "Translation is off (\"translate\" in xtime.config.json)"
        }
      elif bad.len > 0:
        resp Http400, @[("Content-Type", "application/json")], $ %*{"error": bad}
      else:
        try:
          respJson %*{"results": await translateItems(items)}
        except CatchableError as e:
          resp Http502, @[("Content-Type", "application/json")], $ %*{"error": cleanError(e.msg)}

    get "/api/experiments":
      respJson experimentsJson()

    post "/api/experiments":
      # Labs toggles from the dashboard, e.g. {"recommend": true}; persisted in meta.
      try:
        let body = parseJson(request.body)
        if body{"recommend"}.isNil or body{"recommend"}.kind != JBool:
          resp Http400, @[("Content-Type", "application/json")], $ %*{"error": "recommend (bool) is required"}
        else:
          let on = body{"recommend"}.getBool()
          xtimeStore.setMeta(recommendMetaKey, if on: "1" else: "0")
          setRecommendEnabled(on)
          respJson experimentsJson()
      except CatchableError as e:
        resp Http400, @[("Content-Type", "application/json")], $ %*{"error": e.msg}

    get "/api/jobs/@id":
      let job = findJob(@"id")
      if job.isNil:
        resp Http404, @[("Content-Type", "application/json")], $ %*{"error": "unknown job"}
      else:
        respJson jobToJson(job)
