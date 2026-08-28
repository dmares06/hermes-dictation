"""Tests for the flights MCP server. Run: python3 -m unittest -v (from this directory)."""
import json
import os
import subprocess
import sys
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

import flights_mcp as fm

HERE = Path(__file__).parent
FIXTURE = HERE / "fixture_serpapi_cdg_aus.json"


class ValidationTests(unittest.TestCase):
    def test_airport_codes_are_three_letters(self):
        with self.assertRaises(fm.ToolError):
            fm.validate_airport("Louisville")
        self.assertEqual(fm.validate_airport(" sdf "), "SDF")

    def test_dates_must_be_iso_and_ordered(self):
        with self.assertRaises(fm.ToolError):
            fm.validate_date("9/4/2026", "departure_date")
        with self.assertRaises(fm.ToolError):
            fm.build_params(origin="SDF", destination="RDU", departure_date="2026-09-06", return_date="2026-09-04")

    def test_round_trip_and_one_way_map_to_serpapi_types(self):
        rt = fm.build_params(origin="SDF", destination="RDU", departure_date="2026-09-04", return_date="2026-09-06")
        self.assertEqual(rt["type"], "1")
        self.assertEqual(rt["return_date"], "2026-09-06")
        ow = fm.build_params(origin="SDF", destination="RDU", departure_date="2026-09-04")
        self.assertEqual(ow["type"], "2")
        self.assertNotIn("return_date", ow)

    def test_nonstop_and_cabin_flags(self):
        p = fm.build_params(origin="SDF", destination="RDU", departure_date="2026-09-04", nonstop=True, travel_class="business")
        self.assertEqual(p["stops"], "1")
        self.assertEqual(p["travel_class"], "3")


class FormattingTests(unittest.TestCase):
    def setUp(self):
        self.data = json.loads(FIXTURE.read_text())

    def test_options_are_merged_sorted_by_price_and_capped(self):
        options = fm.itineraries(self.data, max_results=3)
        self.assertEqual(len(options), 3)
        prices = [o["price"] for o in options]
        self.assertEqual(prices, sorted(prices))

    def test_summary_reads_like_something_you_could_say_aloud(self):
        text = fm.summarize(self.data, max_results=3, trip="one way")
        self.assertIn("British Airways", text)
        self.assertIn("$520", text)
        self.assertIn("CDG", text)
        self.assertIn("1 stop", text)
        self.assertRegex(text, r"\d{1,2}:\d{2} [AP]M")
        # Price context helps the voice say whether it is a good deal.
        self.assertIn("typical", text.lower())
        self.assertNotIn("airline_logo", text)

    def test_return_tokens_become_short_ids_and_resolve_back(self):
        option = dict(self.data["best_flights"][0], departure_token="x" * 300)
        line = fm.describe(1, option, "round trip")
        self.assertNotIn("x" * 50, line)
        short = line.split("[return_id ")[1].rstrip("]")
        self.assertEqual(len(short), 8)
        self.assertEqual(fm.resolve_token(short), "x" * 300)
        with self.assertRaises(fm.ToolError):
            fm.resolve_token("nope")

    def test_no_flights_is_said_plainly(self):
        text = fm.summarize({"best_flights": [], "other_flights": []}, max_results=3, trip="one way")
        self.assertIn("No flights", text)

    def test_serpapi_error_surfaces(self):
        with self.assertRaises(fm.ToolError):
            fm.summarize({"error": "Google hasn't returned any results for this query."}, max_results=3, trip="one way")


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        os.environ["FLIGHTS_MCP_FIXTURE"] = str(FIXTURE)

    def tearDown(self):
        os.environ.pop("FLIGHTS_MCP_FIXTURE", None)

    def rpc(self, method, params=None, id=1):
        return fm.handle({"jsonrpc": "2.0", "id": id, "method": method, "params": params or {}})

    def test_initialize_and_tool_listing(self):
        init = self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}})
        self.assertEqual(init["result"]["protocolVersion"], "2025-06-18")
        self.assertIn("tools", init["result"]["capabilities"])
        tools = self.rpc("tools/list")["result"]["tools"]
        names = [t["name"] for t in tools]
        self.assertEqual(names, ["search_flights", "return_flights"])
        self.assertEqual(tools[0]["inputSchema"]["required"], ["origin", "destination", "departure_date"])

    def test_notifications_get_no_reply(self):
        self.assertIsNone(fm.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}))

    def test_tool_call_returns_spoken_summary(self):
        reply = self.rpc("tools/call", {"name": "search_flights", "arguments": {
            "origin": "CDG", "destination": "AUS", "departure_date": "2099-03-03"}})
        self.assertFalse(reply["result"].get("isError", False))
        self.assertIn("British Airways", reply["result"]["content"][0]["text"])

    def test_bad_arguments_are_a_tool_error_not_a_crash(self):
        reply = self.rpc("tools/call", {"name": "search_flights", "arguments": {
            "origin": "Paris", "destination": "AUS", "departure_date": "2099-03-03"}})
        self.assertTrue(reply["result"]["isError"])
        self.assertIn("airport code", reply["result"]["content"][0]["text"])

    def test_unknown_method_is_a_jsonrpc_error(self):
        self.assertEqual(self.rpc("nope")["error"]["code"], -32601)

    def test_missing_key_is_explained(self):
        os.environ.pop("FLIGHTS_MCP_FIXTURE", None)
        saved = os.environ.pop("SERPAPI_API_KEY", None)
        original_env_file = fm.HERMES_ENV_FILE
        fm.HERMES_ENV_FILE = HERE / "does-not-exist.env"  # never read the real key, never hit SerpAPI
        try:
            reply = self.rpc("tools/call", {"name": "search_flights", "arguments": {
                "origin": "SDF", "destination": "RDU", "departure_date": "2099-09-04"}})
            self.assertTrue(reply["result"]["isError"])
            self.assertIn("SERPAPI_API_KEY", reply["result"]["content"][0]["text"])
            os.environ["SERPAPI_API_KEY"] = "${SERPAPI_API_KEY}"
            reply = self.rpc("tools/call", {"name": "search_flights", "arguments": {
                "origin": "SDF", "destination": "RDU", "departure_date": "2099-09-04"}})
            self.assertTrue(reply["result"]["isError"])
        finally:
            fm.HERMES_ENV_FILE = original_env_file
            os.environ.pop("SERPAPI_API_KEY", None)
            if saved is not None:
                os.environ["SERPAPI_API_KEY"] = saved


class KeyLookupTests(unittest.TestCase):
    def test_key_falls_back_to_the_hermes_env_file(self):
        saved = os.environ.pop("SERPAPI_API_KEY", None)
        original = fm.HERMES_ENV_FILE
        env_file = HERE / "_test.env"
        env_file.write_text("OTHER=1\nSERPAPI_API_KEY='abc123'\n")
        try:
            fm.HERMES_ENV_FILE = env_file
            self.assertEqual(fm.api_key(), "abc123")
            os.environ["SERPAPI_API_KEY"] = "${SERPAPI_API_KEY}"
            self.assertEqual(fm.api_key(), "abc123", "an unresolved placeholder must not win over the file")
        finally:
            fm.HERMES_ENV_FILE = original
            env_file.unlink()
            os.environ.pop("SERPAPI_API_KEY", None)
            if saved is not None:
                os.environ["SERPAPI_API_KEY"] = saved


class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        os.environ["FLIGHTS_MCP_FIXTURE"] = str(FIXTURE)
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), fm.MCPHTTPHandler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        os.environ.pop("FLIGHTS_MCP_FIXTURE", None)

    def post(self, body):
        data = json.dumps(body).encode()
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/mcp", data=data,
            headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"},
        )
        with urllib.request.urlopen(request, timeout=10) as response:
            raw = response.read()
            return response.status, response.headers.get("Content-Type"), (json.loads(raw) if raw else None)

    def test_requests_get_json_and_notifications_get_202(self):
        status, ctype, body = self.post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}})
        self.assertEqual((status, ctype), (200, "application/json"))
        self.assertEqual(body["result"]["protocolVersion"], "2025-03-26")
        status, _, body = self.post({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.assertEqual((status, body), (202, None))

    def test_tool_call_over_http(self):
        status, _, body = self.post({"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {
            "name": "search_flights", "arguments": {"origin": "CDG", "destination": "AUS", "departure_date": "2099-03-03"}}})
        self.assertEqual(status, 200)
        self.assertIn("British Airways", body["result"]["content"][0]["text"])

    def test_health_and_unsupported_stream(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health", timeout=5) as response:
            self.assertTrue(json.load(response)["ok"])
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(f"http://127.0.0.1:{self.port}/mcp", timeout=5)
        self.assertEqual(caught.exception.code, 405)


class StdioTests(unittest.TestCase):
    def test_server_answers_over_stdio(self):
        messages = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "search_flights", "arguments": {
                "origin": "CDG", "destination": "AUS", "departure_date": "2099-03-03", "max_results": 2}}},
        ]
        env = dict(os.environ, FLIGHTS_MCP_FIXTURE=str(FIXTURE))
        proc = subprocess.run(
            [sys.executable, str(HERE / "flights_mcp.py")],
            input="".join(json.dumps(m) + "\n" for m in messages),
            capture_output=True, text=True, env=env, timeout=20,
        )
        replies = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
        self.assertEqual([r["id"] for r in replies], [1, 2, 3])
        self.assertIn("British Airways", replies[2]["result"]["content"][0]["text"])
        self.assertEqual(proc.stderr.strip(), "", proc.stderr)


if __name__ == "__main__":
    unittest.main()
