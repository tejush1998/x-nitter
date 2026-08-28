import asyncio
import argparse
import json
import os
import sys
import urllib.parse
from datetime import datetime, timezone


def load_cookies(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, dict):
        return data
    cookies = {}
    for item in data:
        name = item.get("name")
        if name:
            cookies[name] = item.get("value", "")
    return cookies


TWITTER_FMT = "%a %b %d %H:%M:%S %z %Y"


def iso(value):
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, (int, float)):
        ts = value / 1000 if value > 1e12 else value
        return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()
    try:
        return datetime.strptime(str(value), TWITTER_FMT).isoformat()
    except (ValueError, TypeError):
        return str(value)


def extract(tweet):
    user = getattr(tweet, "user", None) or {}
    raw = getattr(tweet, "raw", None) or {}

    text = getattr(tweet, "full_text", None) or getattr(tweet, "text", None)
    rt = getattr(tweet, "retweeted_tweet", None)
    if rt is not None:
        rt_text = getattr(rt, "full_text", None) or getattr(rt, "text", None) or ""
        rt_user = getattr(getattr(rt, "user", None), "screen_name", None)
        text = f"RT @{rt_user}: {rt_text}" if rt_user else rt_text

    media = []
    for m in getattr(tweet, "media", None) or []:
        url = getattr(m, "url", None)
        if url:
            media.append(url)
    if not media:
        extended = (raw.get("extended_entities") or {}).get("media") or []
        for m in extended:
            url = m.get("media_url_https") or m.get("media_url")
            if url:
                media.append(url)

    links = []
    for u in getattr(tweet, "urls", None) or []:
        expanded = getattr(u, "expanded_url", None) or getattr(u, "url", None)
        if expanded:
            links.append(expanded)

    return {
        "id": getattr(tweet, "id", None),
        "text": text,
        "author_id": getattr(user, "id", None),
        "author_name": getattr(user, "name", None),
        "author_username": getattr(user, "screen_name", None),
        "created_at": iso(getattr(tweet, "created_at", None)),
        "like_count": getattr(tweet, "favorite_count", None),
        "retweet_count": getattr(tweet, "retweet_count", None),
        "reply_count": getattr(tweet, "reply_count", None),
        "view_count": getattr(tweet, "view_count", None),
        "links": links,
        "media": media,
        "promoted": "promotedMetadata" in raw or raw.get("__typename") == "TweetWithVisibilityResults",
        "raw": raw,
    }


async def main():
    parser = argparse.ArgumentParser(description="Fetch For You timeline via twifork")
    parser.add_argument("--cookies", default="cookies.json")
    parser.add_argument("--count", type=int, default=20)
    parser.add_argument("--pages", type=int, default=3)
    parser.add_argument("--seen", default="", help="comma-separated tweet ids to exclude")
    parser.add_argument("--like", help="tweet id to like")
    parser.add_argument("--unlike", action="store_true", help="instead of liking, unlike the tweet")
    parser.add_argument("--follow", help="username to follow")
    parser.add_argument("--unfollow", help="username to unfollow")
    parser.add_argument("--following", help="check whether you follow a username")
    parser.add_argument("--out", default="", help="write result JSON to file instead of stdout")
    args = parser.parse_args()

    def emit(payload):
        text = json.dumps(payload, ensure_ascii=False)
        if args.out:
            with open(args.out, "w", encoding="utf-8") as f:
                f.write(text)
        else:
            print(text)

    try:
        from twikit import Client
    except ImportError:
        print("twifork not installed. Run: pip install -r requirements.txt", file=sys.stderr)
        sys.exit(3)

    cookies = {}
    env_token = os.environ.get("AUTH_TOKEN")
    env_ct0 = os.environ.get("CT0")
    if env_token or env_ct0:
        cookies["auth_token"] = env_token
        cookies["ct0"] = env_ct0
    else:
        try:
            cookies = load_cookies(args.cookies)
        except FileNotFoundError:
            print(
                f"Cookie file {args.cookies!r} not found and AUTH_TOKEN/CT0 not set in .env. "
                "Export auth_token + ct0 from a logged-in browser session.",
                file=sys.stderr,
            )
            sys.exit(2)
        except json.JSONDecodeError:
            print(f"Cookie file {args.cookies!r} is not valid JSON.", file=sys.stderr)
            sys.exit(2)

    if not cookies.get("auth_token") or not cookies.get("ct0"):
        print("Both 'auth_token' and 'ct0' are required (in .env as AUTH_TOKEN/CT0, or in cookies.json).", file=sys.stderr)
        sys.exit(2)

    client = Client("en-US", impersonate="chrome124")
    client.set_cookies(cookies)

    from twikit.errors import Unauthorized

    for attempt in range(3):
        try:
            await client.user()
            break
        except Unauthorized:
            print("Cookies are expired or invalid. Re-export auth_token + ct0 from your browser.", file=sys.stderr)
            sys.exit(2)
        except Exception as exc:
            if attempt == 2:
                print(f"Auth check failed: {type(exc).__name__}: {exc}", file=sys.stderr)
                sys.exit(2)
            await asyncio.sleep(1.5)

    if args.like:
        from twikit.client.gql import Endpoint
        from twikit.errors import TooManyRequests, Unauthorized as UnauthorizedError

        endpoint = str(Endpoint.UNFAVORITE_TWEET if args.unlike else Endpoint.FAVORITE_TWEET)
        query = "variables=" + urllib.parse.quote(json.dumps({"tweet_id": args.like}))
        try:
            body, response = await client.post(f"{endpoint}?{query}", json={}, headers=client._base_headers)
        except UnauthorizedError:
            print("Cookies are expired or invalid. Re-export auth_token + ct0 from your browser.", file=sys.stderr)
            sys.exit(2)
        except TooManyRequests:
            print("Rate limited by X. Wait a bit before liking more tweets.", file=sys.stderr)
            sys.exit(1)
        except Exception as exc:
            print(f"Like request failed: {exc}", file=sys.stderr)
            sys.exit(1)

        errors = body.get("errors") or []
        ok_codes = {139}  # "already favorited" / "not favorited" races the like state, treat as success
        if response.status_code != 200 or any(e.get("code") not in ok_codes for e in errors):
            detail = "; ".join(e.get("message", str(e)) for e in errors) or f"HTTP {response.status_code}"
            print(f"Like failed: {detail}", file=sys.stderr)
            sys.exit(1)
        emit({"ok": True, "liked": not args.unlike})
        sys.exit(0)

    if args.follow or args.unfollow or args.following:
        username = args.follow or args.unfollow or args.following
        from twikit.errors import NotFound, TooManyRequests, Unauthorized as UnauthorizedError, UserNotFound, UserUnavailable

        try:
            user = await client.get_user_by_screen_name(username)
        except UnauthorizedError:
            print("Cookies are expired or invalid. Re-export auth_token + ct0 from your browser.", file=sys.stderr)
            sys.exit(2)
        except TooManyRequests:
            print("Rate limited by X. Wait a bit before trying again.", file=sys.stderr)
            sys.exit(1)
        except (NotFound, UserNotFound, UserUnavailable):
            print(f"User @{username} not found on X.", file=sys.stderr)
            sys.exit(1)
        except Exception as exc:
            print(f"User lookup failed for @{username}: {exc}", file=sys.stderr)
            sys.exit(1)

        if args.following:
            # Installed twifork's User object doesn't expose the relationship
            # flags, so read them from the raw GraphQL response instead.
            response, _ = await client.gql.user_by_screen_name(username)
            result = response["data"]["user"]["result"]
            following = bool(
                result.get("relationship_perspectives", {}).get("following")
                or result.get("legacy", {}).get("following")
            )
            emit({"ok": True, "username": username, "following": following})
            sys.exit(0)

        try:
            # Installed twifork's follow_user/unfollow_user crash parsing the
            # v1.1 response (User constructor chokes on legacy fields), so call
            # the endpoint directly and ignore the parsed user.
            _, resp = await (client.v11.destroy_friendships(user.id) if args.unfollow
                             else client.v11.create_friendships(user.id))
            if resp.status_code != 200:
                raise RuntimeError(f"HTTP {resp.status_code}")
        except UnauthorizedError:
            print("Cookies are expired or invalid. Re-export auth_token + ct0 from your browser.", file=sys.stderr)
            sys.exit(2)
        except TooManyRequests:
            print("Rate limited by X. Wait a bit before trying again.", file=sys.stderr)
            sys.exit(1)
        except Exception as exc:
            print(f"{'Unfollow' if args.unfollow else 'Follow'} failed for @{username}: {exc}", file=sys.stderr)
            sys.exit(1)

        emit({"ok": True, "username": username, "following": not args.unfollow})
        sys.exit(0)

    seen_ids = [s for s in args.seen.split(",") if s]

    from twikit.client.gql import Endpoint
    from twikit.constants import FEATURES
    from twikit.tweet import tweet_from_data
    from twikit.utils import find_dict

    async def fetch_page(cursor):
        variables = {
            "count": args.count,
            "includePromotedContent": True,
            "latestControlAvailable": True,
            "requestContext": "launch",
            "withCommunity": True,
            "seenTweetIds": seen_ids,
        }
        if cursor:
            variables["cursor"] = cursor
        query = (
            "variables=" + urllib.parse.quote(json.dumps(variables))
            + "&features=" + urllib.parse.quote(json.dumps(FEATURES))
        )
        url = f"{Endpoint.HOME_TIMELINE}?{query}"
        response, _ = await client.get(url, headers=client._base_headers)
        items = find_dict(response, "entries", find_one=True)[0]
        page_tweets = []
        for item in items:
            if "itemContent" not in item.get("content", {}):
                continue
            tweet = tweet_from_data(client, item)
            if tweet is not None:
                page_tweets.append(tweet)
        next_cursor = items[-1]["content"]["value"] if items else None
        return page_tweets, next_cursor

    try:
        tweets = []
        cursor = None
        for _ in range(max(1, args.pages)):
            page_tweets, cursor = await fetch_page(cursor)
            tweets.extend(page_tweets)
            if not cursor:
                break
    except Exception as exc:
        print(f"Timeline fetch failed: {exc}", file=sys.stderr)
        sys.exit(1)

    emit([extract(t) for t in tweets])


if __name__ == "__main__":
    # When called from the server, persist stderr to a file the caller can read
    errfile = os.environ.get("XN_ERRFILE", "")
    if errfile:
        class _Tee:
            def __init__(self, *streams):
                self.streams = streams

            def write(self, data):
                for s in self.streams:
                    s.write(data)

            def flush(self):
                for s in self.streams:
                    s.flush()
        sys.stderr = _Tee(sys.stderr, open(errfile, "w", encoding="utf-8"))
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(130)
