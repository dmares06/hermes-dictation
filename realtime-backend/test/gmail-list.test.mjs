import assert from "node:assert/strict";
import test from "node:test";
import handler from "../api/gmail-list.mjs";
import { listMessages, validateLookup } from "../lib/gmail.mjs";

const env = {
  WHISPERDICT_CLIENT_TOKEN: "client-token",
  GOOGLE_CLIENT_ID: "id",
  GOOGLE_CLIENT_SECRET: "secret",
  GMAIL_REFRESH_TOKEN: "refresh",
};

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

test("lookup validation clamps the count and rejects nonsense", () => {
  assert.deepEqual(validateLookup({}), { query: "", limit: 5 });
  assert.deepEqual(validateLookup({ query: " from:sam ", limit: 99 }), { query: "from:sam", limit: 10 });
  assert.throws(() => validateLookup({ query: "a\nb" }), /invalid_query/);
  assert.throws(() => validateLookup({ query: "x".repeat(201) }), /query_too_long/);
  assert.throws(() => validateLookup({ limit: 0 }), /invalid_limit/);
  assert.throws(() => validateLookup({ query: 7 }), /invalid_query/);
});

test("an empty query reads the recent inbox rather than the whole archive", async () => {
  const urls = [];
  const doFetch = async (url) => {
    urls.push(url);
    if (url.includes("/messages?")) return { ok: true, status: 200, json: async () => ({ messages: [] }) };
    throw new Error(`unexpected ${url}`);
  };
  const messages = await listMessages({ token: "at", query: "", limit: 5, fetch: doFetch });
  assert.deepEqual(messages, []);
  assert.equal(new URL(urls[0]).searchParams.get("q"), "in:inbox newer_than:7d");
});

test("only headers and the snippet come back, never the body", async () => {
  const doFetch = async (url) => {
    if (url.includes("/messages?")) {
      return { ok: true, status: 200, json: async () => ({ messages: [{ id: "m1" }] }) };
    }
    assert.equal(new URL(url).searchParams.get("format"), "metadata");
    return {
      ok: true,
      status: 200,
      json: async () => ({
        id: "m1",
        snippet: "Can we move it to  &quot;Friday&quot;?",
        payload: {
          headers: [
            { name: "From", value: "Sam <sam@example.com>" },
            { name: "Subject", value: "Thursday" },
            { name: "Date", value: "Wed, 26 Aug 2026 09:00:00 -0400" },
            { name: "To", value: "dylan@example.com" },
          ],
        },
      }),
    };
  };
  const messages = await listMessages({ token: "at", query: "from:sam", limit: 5, fetch: doFetch });
  assert.deepEqual(messages, [{
    id: "m1",
    from: "Sam <sam@example.com>",
    subject: "Thursday",
    date: "Wed, 26 Aug 2026 09:00:00 -0400",
    snippet: 'Can we move it to "Friday"?',
  }]);
});

test("a token without the read scope is reported as such, not as a generic failure", async () => {
  const doFetch = async (url) =>
    url.includes("/token")
      ? { ok: true, status: 200, json: async () => ({ access_token: "at" }) }
      : { ok: false, status: 403, json: async () => ({}) };
  const res = fakeResponse();
  await handler(request({ body: { query: "" } }), res, { env, fetch: doFetch });
  assert.equal(res.statusCode, 403);
  assert.equal(res.body.error, "insufficient_scope");
});

test("the endpoint rejects a bad client token before touching Google", async () => {
  let upstreamCalls = 0;
  const res = fakeResponse();
  await handler(request({ auth: "Bearer nope", body: {} }), res, { env, fetch: async () => { upstreamCalls++; } });
  assert.equal(res.statusCode, 401);
  assert.equal(upstreamCalls, 0);
});

test("the endpoint rejects anything but POST", async () => {
  const res = fakeResponse();
  await handler(request({ method: "GET" }), res, { env, fetch: async () => { throw new Error("no"); } });
  assert.equal(res.statusCode, 405);
});
