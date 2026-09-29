#!/usr/bin/env python3
"""
A HexaEight external service for WEATHER, fronting Open-Meteo (free, no API key).

An adapter, not a proxy: Open-Meteo answers in its own shape; an agent's memory search expects the
heia-service/1 shape. This program sits between them — it takes the question, asks Open-Meteo, and
answers in the contract. Copy it as the pattern for any API you want your agent to offer.

THE CONTRACT — heia-service/1:

    GET  /health                          liveness
    GET  /weather/describe?name=<n>       what this is, written FOR THE MODEL   (also /heia/describe)
    POST /heia/search                     {"query": "<place>", "topK": n, "name": "<remote>"}
                                       -> {"contract","op","status":"ok","results":[…]}

ONE RESULT ROW PER THING WORTH CITING: the current weather, then one row per forecast day.

Run:      python3 weather-service.py              (listens on 127.0.0.1:38492)
Publish:  cd <agent folder> && hexaeight-activate add-api --name weather --port 38492
Standard library only — nothing to install. Binds loopback only: reached through the agent, so the
caller is authenticated and the agent's policy applies.
"""
import argparse
import json
import re
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONTRACT = "heia-service/1"
NAME = "weather"
UA = {"User-Agent": "HexaEight-weather-example/1 (+https://github.com/HexaEightTeam/hbia-agent)"}

# WMO weather interpretation codes, as Open-Meteo returns them.
WMO = {
    0: "clear sky", 1: "mainly clear", 2: "partly cloudy", 3: "overcast", 45: "fog", 48: "rime fog",
    51: "light drizzle", 53: "drizzle", 55: "dense drizzle", 56: "freezing drizzle", 57: "freezing drizzle",
    61: "light rain", 63: "rain", 65: "heavy rain", 66: "freezing rain", 67: "freezing rain",
    71: "light snow", 73: "snow", 75: "heavy snow", 77: "snow grains",
    80: "light showers", 81: "showers", 82: "violent showers", 85: "snow showers", 86: "heavy snow showers",
    95: "thunderstorm", 96: "thunderstorm with hail", 99: "thunderstorm with heavy hail",
}

# Words around a place name in a natural question: "what's the weather in Paris tomorrow" -> "Paris".
FILLER = {
    "what", "whats", "what's", "is", "the", "weather", "forecast", "in", "at", "for", "of", "today",
    "tomorrow", "now", "current", "currently", "like", "will", "it", "be", "rain", "temperature",
    "please", "tell", "me", "how", "hot", "cold", "this", "week", "weekend", "a", "an", "and", "going", "to",
}


def get_json(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode("utf-8"))


def place_of(query):
    """The place in the question. Everything else is filler for this service."""
    words = re.findall(r"[A-Za-zÀ-ÿ'.-]+", query or "")
    kept = [w for w in words if w.lower().strip(".'") not in FILLER]
    return " ".join(kept).strip()


def describe(name):
    return {
        "contract": CONTRACT,
        "name": name or NAME,
        "description": (
            "CURRENT WEATHER AND A 3-DAY FORECAST for any town or city, from Open-Meteo. "
            "Search with a PLACE NAME ('London', 'weather in Chennai tomorrow' works too). "
            "Returns one row for the weather now (temperature, feels-like, humidity, wind, conditions) "
            "and one row per day for the next three days (high, low, chance of rain, conditions), "
            "in the place's local time. Temperatures are °C, wind km/h. "
            "It has no history and no alerts. If a place is ambiguous, the most populous match is used "
            "and named in the answer — say the country to pick another."
        ),
        "docs": 1,   # a live service has no corpus, but the registration probe reads docs<=0 as "nothing here"
        "ops": [{"op": "search", "kind": "read",
                 "args": {"query": "string: a place, e.g. 'Paris' or 'Austin, Texas'",
                          "topK": "int: rows to return (default 4)"}}],
    }


def weather(query, limit):
    """(rows, error) — never raises."""
    place = place_of(query)
    if not place:
        return None, "name a place, e.g. 'London' or 'Tokyo'"
    try:
        g = get_json("https://geocoding-api.open-meteo.com/v1/search?"
                     + urllib.parse.urlencode({"name": place, "count": 1, "language": "en", "format": "json"}))
    except Exception as e:                                                   # noqa: BLE001
        return None, f"could not reach the Open-Meteo geocoder: {e}"
    hits = g.get("results") or []
    if not hits:
        return None, f"no place called '{place}' was found"
    p = hits[0]
    where = ", ".join(x for x in (p.get("name"), p.get("admin1"), p.get("country")) if x)
    try:
        f = get_json("https://api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode({
            "latitude": p["latitude"], "longitude": p["longitude"], "timezone": "auto", "forecast_days": 3,
            "current": "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code",
            "daily": "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max",
        }))
    except Exception as e:                                                   # noqa: BLE001
        return None, f"could not reach the Open-Meteo forecast: {e}"

    link = f"https://open-meteo.com/en/docs#latitude={p['latitude']}&longitude={p['longitude']}"
    c = f.get("current") or {}
    rows = [{
        "score": 1.0,
        "document": f"Weather now in {where}",
        "source": link,
        "text": (f"{WMO.get(c.get('weather_code'), 'unknown conditions')}, {c.get('temperature_2m')}°C "
                 f"(feels like {c.get('apparent_temperature')}°C), humidity {c.get('relative_humidity_2m')}%, "
                 f"wind {c.get('wind_speed_10m')} km/h  [local time {c.get('time')}, {f.get('timezone')}]"),
    }]
    d = f.get("daily") or {}
    for i, day in enumerate(d.get("time") or []):
        rows.append({
            "score": round(0.9 - 0.1 * i, 2),
            "document": f"Forecast for {where} on {day}",
            "source": link,
            "text": (f"{WMO.get((d.get('weather_code') or [None])[i], 'unknown conditions')}, "
                     f"high {(d.get('temperature_2m_max') or [None])[i]}°C, "
                     f"low {(d.get('temperature_2m_min') or [None])[i]}°C, "
                     f"chance of rain {(d.get('precipitation_probability_max') or [None])[i]}%"),
        })
    return rows[: max(1, limit)], None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    DESCRIBE = ("/weather/describe", "/heia/describe")
    SEARCH = ("/weather/search", "/heia/search")

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s\n" % (fmt % args))

    def do_GET(self):                                                        # noqa: N802
        u = urllib.parse.urlparse(self.path)
        if u.path == "/health":
            return self._send(200, {"contract": CONTRACT, "status": "ok", "name": NAME,
                                    "upstream": "open-meteo.com", "search": self.SEARCH[1]})
        if u.path in self.DESCRIBE:
            return self._send(200, describe((urllib.parse.parse_qs(u.query).get("name") or [""])[0]))
        self._send(404, {"contract": CONTRACT, "status": "error", "error": "GET /health, GET /weather/describe, POST /heia/search"})

    def do_POST(self):                                                       # noqa: N802
        if urllib.parse.urlparse(self.path).path not in self.SEARCH:
            return self._send(404, {"contract": CONTRACT, "status": "error", "error": "POST /heia/search"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n).decode("utf-8") if n else "{}")
        except Exception as e:                                               # noqa: BLE001
            return self._send(400, {"contract": CONTRACT, "op": "search", "status": "error", "error": f"bad JSON: {e}"})
        try:
            limit = int(body.get("topK") or 4)
        except Exception:                                                    # noqa: BLE001
            limit = 4
        rows, err = weather(str(body.get("query") or ""), limit)
        if err:
            # An ANSWER, not a transport failure: status 200 with the reason, so the model can act on it.
            return self._send(200, {"contract": CONTRACT, "op": "search", "status": "error", "error": err})
        self._send(200, {"contract": CONTRACT, "op": "search", "status": "ok", "results": rows})


def main():
    global NAME
    a = argparse.ArgumentParser(description="HexaEight weather service (Open-Meteo, no key)")
    a.add_argument("--port", type=int, default=38492)
    a.add_argument("--name", default="weather")
    args = a.parse_args()
    NAME = args.name
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"weather-service: listening on http://127.0.0.1:{args.port}  (loopback only)")
    print("  routes: GET /health, GET /weather/describe, POST /heia/search")
    sys.stdout.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
