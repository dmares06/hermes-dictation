# flights-mcp

A dependency-free MCP server (stdio, JSON-RPC) that gives Hermes real Google
Flights itineraries through [SerpAPI](https://serpapi.com/google-flights-api):
airline, departure/arrival times, stops, duration, price, and a price check
against the route's typical range.

Why: web search only sees Google Flights' static "from $333" summary, so the
model invents times and fares. This tool returns the real thing.

## Tools

- `search_flights(origin, destination, departure_date, return_date?, adults?, nonstop?, travel_class?, max_results?)`
- `return_flights(... , return_token)` — return-leg options for a chosen outbound.

Airports are IATA codes; dates are `YYYY-MM-DD`. Cheapest options first.

## Setup

1. Put `SERPAPI_API_KEY=...` in `~/.hermes/.env`.
2. `~/.hermes/config.yaml` has the `mcp_servers.flights` entry pointing at
   `flights_mcp.py` with `env: {SERPAPI_API_KEY: ${SERPAPI_API_KEY}}`.

## Tests

    python3 -m unittest -v

`fixture_serpapi_cdg_aus.json` is SerpAPI's documented sample response; set
`FLIGHTS_MCP_FIXTURE=<path>` to answer from a saved response instead of the API.
