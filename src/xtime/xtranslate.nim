# x-time live translation on Nitter pages: /js/translate.js posts the tweets,
# quoted tweets and bio that X marks as non-English (links swapped for ⟦n⟧),
# one LLM call per request. Results stay in SQLite (translations), keyed by
# tweet id or "bio:<user id>", and are reused while the sent text is the same.
import std/[json, asyncdispatch, strutils, tables]
from std/unicode import runeLen, runeSubStr
from ./xllm import callLlmChat
from ./xconfig import TranslateOpts
from ./xstore import XStore, CachedTranslation, getTranslations, setTranslation

type
  TrItem* = object
    key*: string
    text*: string

const
  maxItems = 20
  maxTextLen = 100_000  # bytes; X long posts reach 25k characters

var
  trOpts: TranslateOpts
  trStore: XStore

proc initTranslate*(opts: TranslateOpts; store: XStore) =
  trOpts = opts
  trStore = store

proc translateEnabled*(): bool =
  trOpts.enabled and trOpts.providers.len > 0

proc clip(s: string; n: int): string =
  if s.runeLen > n: s.runeSubStr(0, n) & "…" else: s

proc cleanError*(msg: string): string =
  ## One line, without the async traceback Nim appends to re-raised errors.
  msg.split("\nAsync traceback:")[0].splitWhitespace().join(" ").clip(300)

const translatePrompt = """You translate X (Twitter) posts and profile bios into natural, fluent English.
Each item has an "id" and a "text". Placeholders like ⟦1⟧ stand for links, @mentions and #hashtags: keep every placeholder exactly as written, where it fits in the English sentence.
Keep the original tone and line breaks. Do not add interpretation or commentary. Keep names, numbers, $cashtags and emoji as they are.
If the text is already English, or is Hindi written in Latin letters (Hinglish), set "same" to true and leave "translation" empty.
For every item give "lang": the English name of the language the text is written in, e.g. "Japanese".
Respond with JSON only, in exactly this shape:
{"results":[{"id":"...","lang":"...","same":false,"translation":"..."}]}
Include exactly one result per input item, using the same id values."""

proc parseTrItems*(body: string): seq[TrItem] =
  ## {"items": [{"id": "<tweet id>" | "bio:<user id>", "text": "..."}]};
  ## raises ValueError on anything else.
  let js = parseJson(body)
  for it in js{"items"}.getElems():
    let key = it{"id"}.getStr()
    let num = if key.startsWith("bio:"): key[4 .. ^1] else: key
    if num.len == 0 or num.len > 20 or not num.allCharsInSet(Digits):
      raise newException(ValueError, "bad id: " & key.clip(40))
    let text = it{"text"}.getStr().strip()
    if text.len == 0 or text.len > maxTextLen:
      raise newException(ValueError, "bad text for " & key)
    result.add TrItem(key: key, text: text)
  if result.len == 0 or result.len > maxItems:
    raise newException(ValueError, "items: 1-" & $maxItems & " are required")

proc chat(userContent: string): Future[JsonNode] {.async.} =
  ## callLlmChat against each configured provider in order until one answers.
  var failures: seq[string]
  for p in trOpts.providers:
    try:
      return await callLlmChat(p.model, p.baseUrl, p.apiKeyEnv,
        translatePrompt, userContent, p.timeoutMs, p.reasoningEffort)
    except CatchableError as e:
      let msg = cleanError(e.msg)
      echo "[xtime] translate: ", p.name, " (", p.model, ") failed: ", msg
      failures.add p.name & ": " & msg
  raise newException(ValueError, "All LLM providers failed — " & failures.join(" | "))

proc resultJson(t: CachedTranslation): JsonNode =
  if t.translation.len == 0: %*{"same": true, "lang": t.lang}
  else: %*{"lang": t.lang, "text": t.translation}

proc translateItems*(items: seq[TrItem]): Future[JsonNode] {.async.} =
  ## {key: {"lang", "text"} | {"same": true}} for each item answered from the
  ## cache or one LLM call; items the model skipped are left out.
  result = newJObject()
  var keys: seq[string]
  for it in items: keys.add it.key
  let cached = trStore.getTranslations(keys)
  var misses = initOrderedTable[string, string]()
  for it in items:
    if it.key in cached and cached[it.key].source == it.text:
      result[it.key] = resultJson(cached[it.key])
    else:
      misses[it.key] = it.text
  if misses.len == 0: return

  var payload = newJArray()
  for key, text in misses: payload.add %*{"id": key, "text": text}
  let parsed = await chat($(%*{"items": payload}))
  for r in parsed{"results"}.getElems():
    let key = r{"id"}.getStr()
    if key notin misses or result.hasKey(key): continue
    var tr = r{"translation"}.getStr().strip()
    if r{"same"}.getBool() or tr == misses[key]: tr = ""
    elif tr.len == 0: continue
    let t = CachedTranslation(source: misses[key], lang: r{"lang"}.getStr().strip(),
                              translation: tr)
    trStore.setTranslation(key, t)
    result[key] = resultJson(t)
