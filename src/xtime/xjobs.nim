# x-time job registry: single active job + history (mirror of server.js jobs)
import std/[json, asyncdispatch, times, options]
import xconfig, xstore, xengine, xllm, xstatus

type
  XJob* = ref object
    id*: string
    kind*: string
    source*: string
    status*: string
    startedAt*: int64
    finishedAt*: int64
    message*: string
    total*: int
    assignments*: int
    error*: string
    result*: JsonNode
    work*: proc(): Future[JsonNode] {.closure.}

  JobBusyError* = object of CatchableError
    activeId*: string

var
  activeJob: XJob = nil
  jobHistory: seq[XJob] = @[]
  jobCounter = 0

proc nowMs(): int64 = epochMs()

proc jobToJson*(j: XJob): JsonNode =
  if j.isNil: return newJNull()
  var elapsed: int64 = 0
  if j.startedAt > 0:
    elapsed = (if j.finishedAt > 0: j.finishedAt else: nowMs()) - j.startedAt
  result = %*{
    "id": j.id,
    "kind": j.kind,
    "source": j.source,
    "status": j.status,
    "startedAt": j.startedAt,
    "finishedAt": j.finishedAt,
    "elapsedMs": elapsed,
    "message": j.message,
    "total": j.total,
    "assignments": j.assignments,
    "error": j.error
  }
  if j.result != nil:
    result["result"] = j.result

proc getActiveJob*(): XJob = activeJob

proc getJobHistory*(): seq[XJob] = jobHistory

proc findJob*(id: string): XJob =
  if not activeJob.isNil and activeJob.id == id: return activeJob
  for j in jobHistory:
    if j.id == id: return j

proc activeCount(assignmentsJson: JsonNode): int =
  if assignmentsJson != nil and assignmentsJson.kind == JArray:
    return assignmentsJson.len
  return 0

proc runJob(job: XJob) {.async.} =
  try:
    let resultJson = await job.work()
    job.result = resultJson
    job.status = "success"
    if resultJson{"message"} != nil:
      job.message = resultJson{"message"}.getStr()
    if resultJson{"total"} != nil:
      job.total = resultJson{"total"}.getInt()
    if resultJson{"assignments"} != nil and resultJson{"assignments"}.kind == JArray:
      job.assignments = resultJson{"assignments"}.len
  except CatchableError as e:
    job.status = "error"
    job.message = e.msg
    job.error = e.msg
  job.finishedAt = nowMs()
  jobHistory.insert(job, 0)
  if jobHistory.len > 15:
    jobHistory.setLen(15)
  activeJob = nil

proc startJob*(kind: string, source: string,
    work: proc(): Future[JsonNode] {.closure.}): XJob =
  ## Raises JobBusyError if another job is active.
  if not activeJob.isNil and activeJob.status == "running":
    var e = new JobBusyError
    e.msg = "Another job is already running"
    e.activeId = activeJob.id
    raise e
  jobCounter.inc
  let job = XJob(
    id: $nowMs() & "-" & $jobCounter,
    kind: kind,
    source: source,
    status: "running",
    startedAt: nowMs(),
    work: work
  )
  activeJob = job
  asyncCheck runJob(job)
  return job

proc maybeAutoScrape*(store: XStore, conf: XTimeConf) =
  ## Auto-scrape on boot when no batch exists for today and poll interval passed.
  let remaining = pollTooSoonNow(store, conf.minPollIntervalSec)
  if store.hasBatchOnDay(now()): return
  if remaining.isSome: return
  echo "[xtime] auto-scrape: no batch for today, starting"
  try:
    discard startJob("scrape", "auto") do() -> Future[JsonNode] {.async.}:
      await scrapePoll(store, conf, conf.countPerPage, conf.pages, "auto")
  except JobBusyError:
    discard
