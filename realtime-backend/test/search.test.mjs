import assert from "node:assert/strict";
import test from "node:test";
import handler from "../api/search.mjs";
import { extractAnswer, SearchError, validateQuery } from "../lib/search.mjs";

const env = { WHISPERDICT_CLIENT_TOKEN: "client-token", OPENAI_API_KEY: "sk-test" };

function fakeResponse() {
  const res = { statusCode: 0, headers: {}, body: undefined };
  res.setHeader = (k, v) => { res.headers[k] = v; };
  res.status = (code) => { res.statusCode = code; return res; };
  res.json = (value) => { res.body = value; return res; };
  res.end = () => res;
  return res;
}

function request({ auth = "Bearer client-token", body, method = "POST" } = {}) {
  return { method, headers: { authorization: auth }, body };
}

test("query validation rejects empty and oversized input", () => {
  assert.equal(validateQuery({ query: "  weather in Austin " }), "weather in Austin");
  assert.throws(() => validateQuery({ query: "   " }), SearchError);
  assert.throws(() => validateQuery({ query: "x".repeat(401) }), SearchError);
  assert.throws(() => validateQuery(null), SearchError);
});

test("the answer and its citations come out of the Responses payload", () => {
  const { answer, sources } = extractAnswer({
    output: [
      { type: "web_search_call" },
      {
        type: "message",
        content: [{
          type: "output_text",
          text: "It is 78 degrees and clear.",
          annotations: [
            { type: "url_citation", url: "https://weather.test/a", title: "Weather" },
            { type: "url_citation", url: "https://weather.test/a", title: "Duplicate" },
          ],
        }],
      },
    ],
  });
  assert.equal(answer, "It is 78 degrees and clear.");
  assert.deepEqual(sources, [{ title: "Weather", url: "https://weather.test/a" }]);
});

test("output_text is preferred when the payload provides it", () => {
  assert.equal(extractAnswer({ output_text: "Short answer.", output: [] }).answer, "Short answer.");
});

test("a long answer is capped so it stays speakable", () => {
  assert.equal(extractAnswer({ output_text: "x".repeat(5000), output: [] }).answer.length, 1200);
});

test("a bad client token is rejected before reaching OpenAI", async () => {
  let calls = 0;
  const res = fakeResponse();
  await handler(request({ auth: "Bearer nope", body: { query: "hi" } }), res, {
    env,
    fetch: async () => { calls++; },
  });
  assert.equal(res.statusCode, 401);
  assert.equal(calls, 0);
});

test("a search returns the answer and asks OpenAI for the web_search tool", async () => {
  const calls = [];
  const res = fakeResponse();
  await handler(request({ body: { query: "who won last night" } }), res, {
    env,
    fetch: async (url, init) => {
      calls.push({ url, init });
      return { ok: true, status: 200, json: async () => ({ output_text: "They did.", output: [] }) };
    },
  });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { ok: true, answer: "They did.", sources: [] });
  assert.equal(calls[0].url, "https://api.openai.com/v1/responses");
  const payload = JSON.parse(calls[0].init.body);
  assert.deepEqual(payload.tools, [{ type: "web_search" }]);
  assert.equal(payload.input, "who won last night");
});

test("an upstream failure is reported without leaking details", async () => {
  const res = fakeResponse();
  await handler(request({ body: { query: "hi" } }), res, {
    env,
    fetch: async () => ({ ok: false, status: 429, json: async () => ({ error: "rate limited" }) }),
  });
  assert.equal(res.statusCode, 502);
  assert.equal(res.body.error, "search_failed");
});
