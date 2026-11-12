# x-time people search for the dashboard's search bar:
# X's People search through nitter's own session pool, flattened to what the
# dropdown shows, plus the list of people opened from it (meta "people.recent").
import std/[json, asyncdispatch, strutils]
import ".."/[types, api, formatters, utils]
from xstore import XStore, getMeta, setMeta

const
  recentKey = "people.recent"
  recentMax = 12

proc searchPeople*(q: string): Future[JsonNode] {.async.} =
  let found = await getGraphUserSearch(Query(kind: users, text: q))
  result = newJArray()
  for u in found.content:
    if u.username.len == 0: continue
    result.add %*{
      "username": u.username,
      "fullname": u.fullname,
      "pic": getPicUrl(u.getUserPic("_bigger")),
      "bio": stripHtml(u.bio),
      "followers": u.followers,
      "verified": u.verifiedType != VerifiedType.none,
      "protected": u.protected
    }

proc validUsername*(s: string): bool =
  s.len in 1..15 and s.allCharsInSet(IdentChars)

proc recentPeople*(store: XStore): JsonNode =
  try:
    result = parseJson(store.getMeta(recentKey))
  except CatchableError:
    result = newJArray()
  if result.kind != JArray: result = newJArray()

proc isPerson(p: JsonNode; username: string): bool =
  p{"username"}.getStr.toLowerAscii == username.toLowerAscii

proc rememberPerson*(store: XStore; person: JsonNode): JsonNode =
  # Newest first, one entry per username. Only nitter's own /pic/ proxy URLs are kept as pictures.
  let username = person{"username"}.getStr.strip(chars = {'@', ' '})
  let pic = person{"pic"}.getStr
  result = %*[{
    "username": username,
    "fullname": person{"fullname"}.getStr,
    "pic": (if pic.startsWith("/pic/"): pic else: ""),
    "verified": person{"verified"}.getBool
  }]
  for p in store.recentPeople:
    if result.len >= recentMax: break
    if not p.isPerson(username): result.add p
  store.setMeta(recentKey, $result)

proc forgetPerson*(store: XStore; username: string): JsonNode =
  result = newJArray()
  for p in store.recentPeople:
    if not p.isPerson(username): result.add p
  store.setMeta(recentKey, $result)
