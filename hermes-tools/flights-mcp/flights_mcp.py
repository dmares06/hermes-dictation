#!/usr/bin/env python3
"""Flights for Hermes: a stdio MCP server over SerpAPI's Google Flights engine.

Why this exists: web search only ever sees Google Flights' static "from $333"
summary, and the model then invents departure times and fares. This returns
real itineraries so the voice can say airline, time, stops, and price.

No dependencies beyond the standard library, so it spawns in well under a
second and needs nothing installed. Speaks MCP JSON-RPC over stdin/stdout.

Two transports:

* ``flights_mcp.py`` — stdio, for clients that spawn the server themselves.
* ``flights_mcp.py --http 8765`` — a persistent streamable-HTTP endpoint at
  ``http://127.0.0.1:8765/mcp``. This is how Hermes uses it: the gateway
  builds a fresh agent per request and spawns/tears down stdio servers with
  each one, which left calls landing on a child that had already exited. A
  long-lived local process has none of that, and discovery is one fast
  request. Run it under launchd (see README).

Hermes config (``mcp_servers``)::

    flights:
      url: http://127.0.0.1:8765/mcp

The SerpAPI key is read from ``SERPAPI_API_KEY`` in the environment, else
from ``~/.hermes/.env``. Set ``FLIGHTS_MCP_FIXTURE=/path/to/serpapi.json`` to
answer from a saved response instead of calling SerpAPI (tests).
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SERPAPI_URL = "https://serpapi.com/search.json"
HERMES_ENV_FILE = Path.home() / ".hermes" / ".env"
DEFAULT_HTTP_PORT = 8765
DEFAULT_PROTOCOL = "2024-11-05"
HTTP_TIMEOUT_S = 25
MAX_RESULTS_CAP = 8

CABINS = {"economy": "1", "premium_economy": "2", "business": "3", "first": "4"}

# SerpAPI's departure_token runs to ~300 characters per option; the model only
# needs a handle. Tokens are kept here (the HTTP server is a long-lived
# process) and handed out as short ids.
RETURN_TOKENS: dict = {}
RETURN_TOKENS_CAP = 500


class ToolError(Exception):
    """A problem worth telling the model about, in words it can relay."""


# --- request building ------------------------------------------------------

def validate_airport(value) -> str:
    code = str(value or "").strip().upper()
    if len(code) != 3 or not code.isalpha():
        raise ToolError(
            f"'{value}' is not a 3-letter IATA airport code. Use codes like SDF (Louisville) or RDU (Raleigh)."
        )
    return code


def validate_date(value, field: str) -> str:
    text = str(value or "").strip()
    try:
        dt.date.fromisoformat(text)
    except ValueError:
        raise ToolError(f"{field} must be a date like 2026-09-04, got '{value}'.") from None
    return text


def build_params(*, origin, destination, departure_date, return_date=None, adults=1,
                 nonstop=False, travel_class="economy", currency="USD") -> dict:
    params = {
        "engine": "google_flights",
        "departure_id": validate_airport(origin),
        "arrival_id": validate_airport(destination),
        "outbound_date": validate_date(departure_date, "departure_date"),
        "currency": currency,
        "hl": "en",
        "adults": str(max(1, int(adults or 1))),
        "travel_class": CABINS.get(str(travel_class or "economy").lower(), "1"),
    }
    if return_date:
        params["return_date"] = validate_date(return_date, "return_date")
        if params["return_date"] < params["outbound_date"]:
            raise ToolError("return_date is before departure_date.")
        params["type"] = "1"  # round trip
    else:
        params["type"] = "2"  # one way
    if nonstop:
        params["stops"] = "1"
    return params


# --- SerpAPI ----------------------------------------------------------------

def fetch(params: dict) -> dict:
    fixture = os.environ.get("FLIGHTS_MCP_FIXTURE")
    if fixture:
        with open(fixture, encoding="utf-8") as handle:
            return json.load(handle)
    key = api_key()
    if not key:
        raise ToolError(
            "The flights tool has no SERPAPI_API_KEY. Add it to ~/.hermes/.env on the Mac and try again."
        )
    query = urllib.parse.urlencode({**params, "api_key": key})
    request = urllib.request.Request(f"{SERPAPI_URL}?{query}", headers={"User-Agent": "hermes-flights-mcp/1"})
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_S) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")[:300]
        raise ToolError(f"SerpAPI answered {error.code}: {body}") from None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise ToolError(f"Could not reach SerpAPI: {error}") from None


def api_key() -> str:
    """SERPAPI_API_KEY from the environment, else from ~/.hermes/.env, so the
    key lives in one place on the Mac. An unresolved "${...}" placeholder
    counts as missing rather than being sent to SerpAPI as a key."""
    key = os.environ.get("SERPAPI_API_KEY", "").strip()
    if key and not key.startswith("${"):
        return key
    try:
        for line in HERMES_ENV_FILE.read_text(encoding="utf-8").splitlines():
            name, sep, value = line.strip().partition("=")
            if sep and name.strip() == "SERPAPI_API_KEY":
                return value.strip().strip("'\"")
    except OSError:
        pass
    return ""


# --- formatting ---------------------------------------------------------------

def itineraries(data: dict, *, max_results: int) -> list:
    options = list(data.get("best_flights") or []) + list(data.get("other_flights") or [])
    options = [o for o in options if isinstance(o, dict) and o.get("flights")]
    options.sort(key=lambda o: (o.get("price") is None, o.get("price") or 0, o.get("total_duration") or 0))
    return options[:max(1, min(int(max_results or 5), MAX_RESULTS_CAP))]


def clock(stamp: str) -> str:
    """'2026-09-04 07:05' -> 'Fri Sep 4, 7:05 AM'."""
    try:
        when = dt.datetime.strptime(stamp, "%Y-%m-%d %H:%M")
    except (TypeError, ValueError):
        return str(stamp)
    hour = when.strftime("%I").lstrip("0") or "12"
    return f"{when.strftime('%a %b')} {when.day}, {hour}:{when.strftime('%M %p')}"


def duration(minutes) -> str:
    try:
        minutes = int(minutes)
    except (TypeError, ValueError):
        return "?"
    hours, rest = divmod(minutes, 60)
    return f"{hours}h {rest:02d}m" if hours else f"{rest}m"


def describe(index: int, option: dict, trip: str) -> str:
    legs = option["flights"]
    first, last = legs[0], legs[-1]
    airlines = []
    for leg in legs:
        name = leg.get("airline") or "?"
        if name not in airlines:
            airlines.append(name)
    stops = len(legs) - 1
    layovers = option.get("layovers") or []
    if stops == 0:
        route = "nonstop"
    else:
        vias = ", ".join(f"{l.get('id', '?')} {duration(l.get('duration'))}" for l in layovers) or "?"
        route = f"{stops} stop via {vias}" if stops == 1 else f"{stops} stops via {vias}"
    price = option.get("price")
    price_text = f"${price:,}" if isinstance(price, (int, float)) else "price unavailable"
    numbers = " ".join(leg.get("flight_number", "") for leg in legs).strip()
    line = (
        f"{index}. {' + '.join(airlines)} — {route}, {duration(option.get('total_duration'))} total — "
        f"{first['departure_airport'].get('id', '?')} {clock(first['departure_airport'].get('time', ''))} → "
        f"{last['arrival_airport'].get('id', '?')} {clock(last['arrival_airport'].get('time', ''))} — "
        f"{price_text} {trip}"
    )
    if numbers:
        line += f" ({numbers})"
    if option.get("departure_token"):
        line += f"  [return_id {remember_token(option['departure_token'])}]"
    return line


def remember_token(token: str) -> str:
    short = hashlib.sha1(token.encode("utf-8")).hexdigest()[:8]
    if short not in RETURN_TOKENS and len(RETURN_TOKENS) >= RETURN_TOKENS_CAP:
        RETURN_TOKENS.pop(next(iter(RETURN_TOKENS)))
    RETURN_TOKENS[short] = token
    return short


def resolve_token(value: str) -> str:
    """A short id from search_flights, or a raw SerpAPI token passed through."""
    value = str(value or "").strip()
    if value in RETURN_TOKENS:
        return RETURN_TOKENS[value]
    if len(value) > 40:
        return value
    raise ToolError("Unknown return_id. Run search_flights again and use one of its return_id values.")


def price_context(data: dict) -> str:
    insights = data.get("price_insights") or {}
    low, level, band = insights.get("lowest_price"), insights.get("price_level"), insights.get("typical_price_range")
    if not (low and band and len(band) == 2):
        return ""
    return f"Price check: lowest right now is ${low:,} which is {level or 'typical'}; typical range for this route is ${band[0]:,}–${band[1]:,}."


def summarize(data: dict, *, max_results: int, trip: str) -> str:
    if data.get("error"):
        raise ToolError(f"SerpAPI: {data['error']}")
    options = itineraries(data, max_results=max_results)
    if not options:
        return "No flights were found for those airports and dates. Try nearby dates or airports."
    lines = [describe(i, option, trip) for i, option in enumerate(options, start=1)]
    note = price_context(data)
    if note:
        lines.append(note)
    if trip == "round trip":
        lines.append(
            "Prices are round-trip totals for the outbound shown; call return_flights with an option's "
            "return_id to see return-leg choices, or say the outbound and price and offer to check returns."
        )
    link = (data.get("search_metadata") or {}).get("google_flights_url")
    if link:
        lines.append(f"Book: {link}")
    return "\n".join(lines)


# --- tools ---------------------------------------------------------------------

COMMON_PROPERTIES = {
    "origin": {"type": "string", "description": "Departure airport IATA code, e.g. SDF for Louisville."},
    "destination": {"type": "string", "description": "Arrival airport IATA code, e.g. RDU for Raleigh-Durham."},
    "departure_date": {"type": "string", "description": "Outbound date, YYYY-MM-DD."},
    "return_date": {"type": "string", "description": "Return date, YYYY-MM-DD. Omit for one way."},
    "adults": {"type": "integer", "description": "Passengers, default 1."},
    "nonstop": {"type": "boolean", "description": "Only nonstop flights. Default false."},
    "travel_class": {"type": "string", "enum": list(CABINS), "description": "Cabin, default economy."},
    "max_results": {"type": "integer", "description": "How many options to return (1-8), default 5."},
}

TOOLS = [
    {
        "name": "search_flights",
        "description": (
            "Real Google Flights itineraries with airline, departure and arrival times, stops, duration and price. "
            "Use this for any flight question instead of web search; never state times or fares it did not return. "
            "Airports must be IATA codes. Returns the cheapest options first."
        ),
        "inputSchema": {
            "type": "object",
            "properties": COMMON_PROPERTIES,
            "required": ["origin", "destination", "departure_date"],
            "additionalProperties": False,
        },
    },
    {
        "name": "return_flights",
        "description": (
            "Return-leg options for a round trip after search_flights: pass the same search arguments plus the "
            "return_id of the chosen outbound option."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {**COMMON_PROPERTIES, "return_id": {"type": "string", "description": "The return_id shown on a search_flights option."}},
            "required": ["origin", "destination", "departure_date", "return_date", "return_id"],
            "additionalProperties": False,
        },
    },
]


def run_tool(name: str, arguments: dict) -> str:
    if name not in {"search_flights", "return_flights"}:
        raise ToolError(f"Unknown tool '{name}'.")
    fields = {k: arguments.get(k) for k in ("origin", "destination", "departure_date", "return_date", "adults",
                                            "nonstop", "travel_class")}
    params = build_params(**{k: v for k, v in fields.items() if v is not None})
    if name == "return_flights":
        params["departure_token"] = resolve_token(arguments.get("return_id") or arguments.get("return_token"))
    trip = "round trip" if params["type"] == "1" else "one way"
    data = fetch(params)
    return summarize(data, max_results=arguments.get("max_results") or 5, trip=trip)


# --- JSON-RPC over stdio ---------------------------------------------------------

def handle(message: dict):
    """One JSON-RPC message in, one reply out (None for notifications)."""
    method = message.get("method")
    msg_id = message.get("id")
    params = message.get("params") or {}
    if msg_id is None:
        return None  # notifications need no reply
    if method == "initialize":
        return reply(msg_id, {
            "protocolVersion": params.get("protocolVersion") or DEFAULT_PROTOCOL,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "hermes-flights", "version": "1.0.0"},
        })
    if method == "ping":
        return reply(msg_id, {})
    if method == "tools/list":
        return reply(msg_id, {"tools": TOOLS})
    if method == "tools/call":
        try:
            text = run_tool(params.get("name", ""), params.get("arguments") or {})
            return reply(msg_id, {"content": [{"type": "text", "text": text}], "isError": False})
        except ToolError as error:
            return reply(msg_id, {"content": [{"type": "text", "text": str(error)}], "isError": True})
        except Exception as error:  # a bug should not take the server down
            return reply(msg_id, {"content": [{"type": "text", "text": f"flights tool failed: {error!r}"}], "isError": True})
    return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32601, "message": f"Method not found: {method}"}}


def reply(msg_id, result) -> dict:
    return {"jsonrpc": "2.0", "id": msg_id, "result": result}


# --- streamable HTTP ------------------------------------------------------------

class MCPHTTPHandler(BaseHTTPRequestHandler):
    """Streamable-HTTP MCP: JSON-RPC over POST /mcp, JSON responses only.

    Requests get ``200 application/json``; notifications get ``202``. The
    optional server-to-client SSE stream (GET) is declined with 405, which
    the spec allows for servers that never push."""

    server_version = "hermes-flights/1.0"

    def do_POST(self):  # noqa: N802 - http.server naming
        if self.path.rstrip("/") not in ("/mcp", ""):
            return self._send(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length") or 0)
            message = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self._send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
        if isinstance(message, list):
            replies = [r for r in (handle(m) for m in message if isinstance(m, dict)) if r is not None]
            return self._send(200, replies) if replies else self._send(202)
        response = handle(message) if isinstance(message, dict) else None
        return self._send(200, response) if response is not None else self._send(202)

    def do_GET(self):  # noqa: N802
        if self.path.rstrip("/") == "/health":
            return self._send(200, {"ok": True, "has_key": bool(api_key())})
        self._send(405)

    def do_DELETE(self):  # noqa: N802
        self._send(200)

    def _send(self, status: int, body=None) -> None:
        payload = json.dumps(body).encode("utf-8") if body is not None else b""
        self.send_response(status)
        if payload:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def log_message(self, format, *args):  # noqa: A002 - quiet by default
        if os.environ.get("FLIGHTS_MCP_VERBOSE"):
            sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))


def serve_http(port: int) -> None:
    server = ThreadingHTTPServer(("127.0.0.1", port), MCPHTTPHandler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def serve() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        response = handle(message)
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--http":
        serve_http(int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_HTTP_PORT)
    else:
        serve()
