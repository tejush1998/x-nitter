# x-time classify status singleton (mirror of lib/status.js)
import std/[times, options, strutils, json, sequtils]

type
  ClassifyAttempt* = object
    label*: string
    model*: string
    baseUrl*: string
    timeoutMs*: int
    chunk*: int
    chunks*: int

  CurrentAttempt* = object
    label*: string
    model*: string
    baseUrl*: string
    timeoutMs*: int
    chunk*: int
    chunks*: int

  XStatus* = object
    running*: bool
    source*: string
    jobId*: string
    phase*: string
    message*: string
    total*: int
    done*: int
    attempts*: seq[ClassifyAttempt]
    current*: Option[CurrentAttempt]
    error*: string
    startedAt*: int64
    finishedAt*: int64

var st: XStatus

proc nowMs(): int64 = getTime().toUnix * 1000'i64

proc cleanErrMsg*(m: string): string =
  # Nim re-raise appends async tracebacks; keep the message only
  m.split("\nAsync traceback:")[0].strip()

proc beginClassify*(source: string, jobId: string, total = 0) =
  st = XStatus(
    running: true,
    source: source,
    jobId: jobId,
    phase: "starting",
    startedAt: nowMs(),
    total: total
  )

proc setClassifyPhase*(phase: string, total = -1, message = "") =
  if not st.running: return
  st.phase = phase
  if message.len > 0: st.message = message
  if total >= 0:
    st.total = total
    st.done = 0

proc setClassifyAttempt*(attempt: CurrentAttempt) =
  st.current = some(attempt)
  for a in st.attempts:
    if a.label == attempt.label and a.model == attempt.model and a.baseUrl == attempt.baseUrl:
      return
  st.attempts.add ClassifyAttempt(
    label: attempt.label, model: attempt.model, baseUrl: attempt.baseUrl,
    timeoutMs: attempt.timeoutMs, chunk: attempt.chunk, chunks: attempt.chunks)

proc addClassifyProgress*(n: int) =
  st.done += n

proc finishClassify*(ok: bool, error = "", message = "") =
  st.running = false
  st.phase = if ok: "done" else: "error"
  if error.len > 0: st.error = cleanErrMsg(error)
  if message.len > 0: st.message = message
  st.current = none(CurrentAttempt)
  st.finishedAt = nowMs()

proc classifyStatus*(): XStatus =
  st

proc statusJson*(s: XStatus): JsonNode =
  result = %*{
    "running": s.running,
    "source": s.source,
    "jobId": s.jobId,
    "phase": s.phase,
    "message": s.message,
    "total": s.total,
    "done": s.done,
    "attempts": s.attempts.mapIt(%*{
      "label": it.label,
      "model": it.model,
      "baseUrl": it.baseUrl,
      "timeoutMs": it.timeoutMs,
      "timeoutSec": (if it.timeoutMs > 0: ((it.timeoutMs + 500) div 1000) else: 0),
      "chunk": it.chunk,
      "chunks": it.chunks
    }),
    "error": s.error,
    "startedAt": s.startedAt,
    "finishedAt": s.finishedAt,
    "elapsedMs": (if s.finishedAt > 0: s.finishedAt - s.startedAt
                  else: nowMs() - s.startedAt)
  }
  if s.current.isSome:
    let c = s.current.get
    result["current"] = %*{
      "label": c.label,
      "model": c.model,
      "baseUrl": c.baseUrl,
      "timeoutMs": c.timeoutMs,
      "timeoutSec": (if c.timeoutMs > 0: ((c.timeoutMs + 500) div 1000) else: 0),
      "chunk": c.chunk,
      "chunks": c.chunks
    }
