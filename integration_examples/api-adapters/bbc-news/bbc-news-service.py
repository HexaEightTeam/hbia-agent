#!/usr/bin/env python3
"""
A HexaEight external service for BBC News headlines, fronting the public BBC RSS feeds.

NO CREDENTIAL HERE — the feeds are public. It still runs as a shim for the other two reasons a shim
exists: it NORMALISES the answer into the one shape every served endpoint returns, and it is the
place the description lives, which is what a model reads to decide whether to use it at all.

THE CONTRACT — heia-service/1:

    GET  /health                    liveness
    GET  /heia/describe?name=<n>    what this is, written FOR THE MODEL
    POST /heia/search               {"query": "<topic>", "topK": n, "name": "<remote>"}
                                 -> {"contract","op","status":"ok","results":[…]}

ONE STORY PER RESULT ROW. A headline is a hit: `document` is the headline, `source` is the BBC link
so the reader can follow it, and `text` carries the summary and when it was published. That is what
lets a runner cite a story rather than paraphrase a blob.

BINDS LOOPBACK ONLY, like every service an agent fronts. It holds no key, but it must still be
reached through the agent so the caller is authenticated and policy applies.
"""
import argparse
import html as html_mod
import json
import re
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONTRACT = "heia-service/1"
NAME = "bbc-news"

FEEDS = {
    "top":           "http://feeds.bbci.co.uk/news/rss.xml",
    "world":         "http://feeds.bbci.co.uk/news/world/rss.xml",
    "uk":            "http://feeds.bbci.co.uk/news/uk/rss.xml",
    "business":      "http://feeds.bbci.co.uk/news/business/rss.xml",
    "politics":      "http://feeds.bbci.co.uk/news/politics/rss.xml",
    "technology":    "http://feeds.bbci.co.uk/news/technology/rss.xml",
    "science":       "http://feeds.bbci.co.uk/news/science_and_environment/rss.xml",
    "health":        "http://feeds.bbci.co.uk/news/health/rss.xml",
    "entertainment": "http://feeds.bbci.co.uk/news/entertainment_and_arts/rss.xml",
    "sport":         "http://feeds.bbci.co.uk/sport/rss.xml",
}

# Words a request is likely to use for each topic. A model asking "what's happening in tech" should
# be served, not refused on a vocabulary mismatch — but an unrecognised topic is still an ANSWER
# listing what exists, never a silent fallback to the front page.
ALIASES = {
    "top": ("headline", "headlines", "top", "latest", "news", "breaking", "front page"),
    "world": ("world", "international", "global", "foreign", "abroad"),
    "uk": ("uk", "britain", "british", "england", "scotland", "wales"),
    "business": ("business", "economy", "economic", "markets", "finance", "trade"),
    "politics": ("politics", "political", "parliament", "government", "westminster", "election"),
    "technology": ("technology", "tech", "ai", "software", "computing", "internet", "digital"),
    "science": ("science", "scientific", "environment", "climate", "space", "research"),
    "health": ("health", "medical", "medicine", "nhs", "disease", "healthcare"),
    "entertainment": ("entertainment", "arts", "film", "movies", "music", "celebrity", "culture"),
    "sport": ("sport", "sports", "football", "cricket", "rugby", "tennis", "olympics"),
}


# Words that carry no signal in a two-or-three word news query. Kept short on purpose: an
# aggressive stop list throws away the very words a search is about ("us", "uk", "war").
STOPWORDS = {
    "the", "and", "for", "with", "about", "from", "into", "what", "whats", "news", "latest",
    "story", "stories", "any", "some", "this", "that", "there", "have", "has", "was", "were",
    "are", "been", "being", "tell", "show", "give", "find", "happening", "happened", "today",
}


def resolve_topic(query):
    """A query -> a feed name, or None. Exact name first, then the alias vocabulary.

    MATCH WHOLE WORDS, NOT SUBSTRINGS. `"uk" in "ukraine"` is true, so a substring test sent every
    search for Ukraine to the UK front page and the caller got three unrelated British stories with
    no indication anything had been substituted. Measured on a live call. The same trap waits in
    "ai" inside "said", "sport" inside "transport".

    A query is a topic only when it is SHORT: "technology" is a topic, "what is technology doing to
    employment" is a search that happens to contain one. Long queries fall through to search, which
    is the more useful answer for anything phrased as a question.
    """
    q = (query or "").strip().lower()
    if not q:
        return None
    if q in FEEDS:
        return q

    terms = re.findall(r"[a-z0-9']+", q)
    if not terms or len(terms) > 4:
        return None                       # a sentence is a search, not a topic

    for topic, words in ALIASES.items():
        if any(w in terms for w in words if " " not in w):
            return topic
        # Multi-word aliases ("front page") are matched against the whole query.
        if any(w in q for w in words if " " in w):
            return topic
    return None


def describe(name):
    """What the model is told. Says what it answers AND what it does not — a service described
    only as "news" gets asked for last week's coverage and for full article text, neither of
    which an RSS feed carries."""
    return {
        "contract": CONTRACT,
        "name": name or NAME,
        "description": (
            "CURRENT BBC NEWS from the BBC's public feeds. Ask it in any of three ways. "
            "(1) A TOPIC — " + ", ".join(sorted(FEEDS)) + " — returns that feed's latest stories; "
            "plain wording works too ('tech', 'the economy', 'football'). "
            "(2) ANYTHING ELSE is treated as a SEARCH across every feed: 'Ukraine', 'interest "
            "rates', a company or person's name returns the stories currently mentioning it, "
            "best match first. "
            "(3) AN EMPTY QUERY returns the front page. "
            "Each result is ONE STORY: the headline, the BBC link to it, the summary, and when it "
            "was published. CITE THE LINK — it is the article. "
            "IT IS HEADLINES AND SUMMARIES, NOT FULL ARTICLES: follow the link to read one. "
            "IT HAS NO ARCHIVE — only what is on the feeds right now — so it cannot answer what "
            "was reported last week, and two calls hours apart will differ. A search finding "
            "nothing usually means the subject is not in today's news, not that it is unknown."
        ),
        # Live feed, no corpus — but the registration probe reads docs<=0 as "nothing here".
        "docs": 1,
        "ops": [
            {
                "op": "search",
                "kind": "read",
                "args": {"query": "string: a topic, e.g. 'technology' or 'world'",
                         "topK": "int: how many stories (default 10)"},
            }
        ],
    }


def clean(s):
    """RSS text with entities decoded and any stray markup removed."""
    if not s:
        return ""
    return re.sub(r"\s+", " ", html_mod.unescape(re.sub(r"<[^>]+>", " ", s))).strip()


def fetch(topic, limit):
    """Read one feed. Returns (rows, error) — never raises.

    EVERYTHING COMES FROM THE FEED. An earlier version fetched each article page to get a longer
    snippet; that was wrong twice over. A BBC article page is a 438 KB JavaScript shell with no
    article text in the HTML at all — what it does contain is the navigation menu, which is exactly
    what got returned as the "snippet". And fetching ten pages to enrich a feed that already
    carries a summary is ten times the work for less.

    The feed gives a headline, a citable link, a summary and a publication time per story. That is
    the story, and it is what a caller needs to decide whether to follow the link.
    """
    req = urllib.request.Request(
        FEEDS[topic],
        headers={"User-Agent": "Mozilla/5.0 (compatible; HexaEight-BBC-Service)"},
    )
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            raw = resp.read()
    except Exception as e:                                      # noqa: BLE001
        return None, f"could not reach the BBC feed for '{topic}': {e}"

    try:
        root = ET.fromstring(raw)
    except ET.ParseError as e:
        return None, f"the BBC feed for '{topic}' was not valid RSS: {e}"

    rows = []
    for item in root.findall(".//item")[: max(1, limit)]:
        def txt(tag, _it=item):
            el = _it.find(tag)
            return clean(el.text) if el is not None else ""

        headline  = txt("title") or "(untitled)"
        link      = txt("link")
        summary   = txt("description")
        published = txt("pubDate")

        body = summary or "(no summary in the feed)"
        if published:
            body += f"  [published {published}]"
        body += f"  [topic: {topic}]"

        rows.append({"score": 1.0, "document": headline, "source": link, "text": body})
    return rows, None


def search_all(query, limit):
    """Stories mentioning `query`, across every feed, best match first.

    Reads all ten feeds in parallel — they are small and cached upstream, so this costs about as
    much as reading one. Scoring is deliberately simple: a hit in the headline outranks a hit in
    the summary, and a story matching more of the query's words outranks one matching fewer. There
    is no index here and there should not be; this is ten RSS files, not a corpus.
    """
    words = [w for w in re.findall(r"[a-z0-9']{3,}", query.lower())
             if w not in STOPWORDS]
    if not words:
        words = [query.lower().strip()]

    by_topic, errors = {}, []
    with ThreadPoolExecutor(max_workers=len(FEEDS)) as pool:
        futures = {pool.submit(fetch, t, 40): t for t in FEEDS}
        for fut in as_completed(futures, timeout=40):
            topic = futures[fut]
            try:
                rows, err = fut.result()
                if err:
                    errors.append(err)
                else:
                    by_topic[topic] = rows
            except Exception as e:                              # noqa: BLE001
                errors.append(f"{topic}: {e}")

    if not by_topic:
        return None, "could not reach the BBC feeds: " + ("; ".join(errors) if errors else "unknown")

    scored, seen_links = [], set()
    for rows in by_topic.values():
        for r in rows:
            link = r.get("source") or ""
            if link and link in seen_links:
                continue                                        # the same story sits on several feeds
            head = (r.get("document") or "").lower()
            body = (r.get("text") or "").lower()

            score = 0.0
            for w in words:
                if w in head: score += 2.0
                elif w in body: score += 1.0
            if score == 0:
                continue

            seen_links.add(link)
            hit = dict(r)
            hit["score"] = round(score / (2.0 * len(words)), 3)   # 1.0 = every word in the headline
            scored.append(hit)

    scored.sort(key=lambda h: h["score"], reverse=True)
    return scored[: max(1, limit)], None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, code, message):
        self._send(code, {"contract": CONTRACT, "op": "search", "status": "error", "error": message})

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s\n" % (fmt % args))

    # THE PATH IS THE SERVICE'S OWN CHOICE — a caller's pointer names it, falling back to
    # /heia/search only when unset. /news says what this is at a glance; the generic path stays
    # as an alias so a pointer written either way works.
    DESCRIBE = ("/news/describe", "/heia/describe")
    SEARCH   = ("/news", "/news/search", "/heia/search")

    def do_GET(self):                                           # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        if path == "/health":
            self._send(200, {"contract": CONTRACT, "status": "ok", "name": NAME,
                             "upstream": "feeds.bbci.co.uk", "topics": sorted(FEEDS),
                             "search": self.SEARCH[0]})
            return
        if path in self.DESCRIBE:
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            self._send(200, describe((q.get("name") or [""])[0]))
            return
        self._error(404, f"GET {self.DESCRIBE[0]}, GET /health, or POST {self.SEARCH[0]}")

    def do_POST(self):                                          # noqa: N802
        if urllib.parse.urlparse(self.path).path not in self.SEARCH:
            self._error(404, f"GET {self.DESCRIBE[0]}, GET /health, or POST {self.SEARCH[0]}")
            return

        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n).decode("utf-8") if n else "{}")
        except Exception as e:                                  # noqa: BLE001
            self._error(400, f"bad JSON body: {e}")
            return

        query = (body.get("query") or "").strip()

        try:
            limit = int(body.get("topK") or 10)
        except Exception:                                       # noqa: BLE001
            limit = 10

        # NO QUERY AT ALL = the front page. Asking a news service for "the news" is a real request,
        # not a malformed one, and refusing it teaches the model to stop asking.
        if not query:
            rows, err = fetch("top", limit)
            if err:
                self._error(200, err)
                return
            self._send(200, {"contract": CONTRACT, "op": "search", "status": "ok", "results": rows})
            return

        topic = resolve_topic(query)
        if topic is not None:
            rows, err = fetch(topic, limit)
            if err:
                self._error(200, err)
                return
            self._send(200, {"contract": CONTRACT, "op": "search", "status": "ok", "results": rows})
            return

        # NOT A TOPIC — SO SEARCH FOR IT. "Ukraine", "interest rates", a company name: none of
        # these are feed names, and refusing them with a list of topics is useless to someone who
        # wants stories ABOUT something. Every feed is read and matched on words, so the answer is
        # "the stories currently mentioning this", which is what was asked.
        rows, err = search_all(query, limit)
        if err:
            self._error(200, err)
            return
        if not rows:
            # Answered, and genuinely nothing — distinct from a refusal, and says what that means.
            self._error(200, f"no current BBC story mentions '{query}'. The feeds carry only what "
                             f"is on them now, so this may simply not be in the news today. "
                             f"Topic feeds available: " + ", ".join(sorted(FEEDS)))
            return
        self._send(200, {"contract": CONTRACT, "op": "search", "status": "ok", "results": rows})


def main():
    global NAME
    p = argparse.ArgumentParser(description="HexaEight BBC News service (public RSS)")
    p.add_argument("--port", type=int, default=38491)
    p.add_argument("--name", default="bbc-news")
    a = p.parse_args()
    NAME = a.name

    host = "127.0.0.1"          # loopback only: reached through the agent, never directly
    srv = ThreadingHTTPServer((host, a.port), Handler)
    print(f"bbc-news-service: listening on http://{host}:{a.port}  (loopback only)")
    print("  routes: GET /health, GET /heia/describe, POST /heia/search")
    print("  topics: " + ", ".join(sorted(FEEDS)))
    sys.stdout.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
