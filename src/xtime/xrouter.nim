# x-time jester router: UI + API (replaces server.js; CORS hack removed)
import std/[json, strutils, asyncdispatch, options, uri, os]
import jester
import xconfig, xstore, xscraper, xstatus, xengine, xjobs
import ../routes/router_utils

# Re-export what nitter.nim needs, but NOT xstore.Tweet / Assignment
# (clashes with types.Tweet inside jester's routes macro expansion).
export xconfig, xjobs, xengine, xscraper, xstatus
export xstore except Tweet, Assignment

var
  xtimeStore*: XStore = nil
  xtimeConf*: XTimeConf

proc createXTimeRouter*(store: XStore, conf: XTimeConf) =
  xtimeStore = store
  xtimeConf = conf
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

    get "/api/jobs/@id":
      let job = findJob(@"id")
      if job.isNil:
        resp Http404, @[("Content-Type", "application/json")], $ %*{"error": "unknown job"}
      else:
        respJson jobToJson(job)
