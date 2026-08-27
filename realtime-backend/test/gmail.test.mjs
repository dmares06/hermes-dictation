import assert from "node:assert/strict";
import test from "node:test";
import handler from "../api/gmail-send.mjs";
import { authorizationURL, buildRawMessage, gmailConfigured, oauthState, validateDraft } from "../lib/gmail.mjs";

const env = {
  WHISPERDICT_CLIENT_TOKEN: "client-token",
  GOOGLE_CLIENT_ID: "id",
  GOOGLE_CLIENT_SECRET: "secret",
  GMAIL_REFRESH_TOKEN: "refresh",
};

function decodeRaw(raw) {
  return Buffer.from(raw, "base64url").toString("utf8");
}

test("raw message is RFC 2822 with a base64 body and base64url overall", () => {
  const raw = buildRawMessage({ to: "sam@example.com", subject: "Thursday", body: "See you at 3." });
  assert.doesNotMatch(raw, /[+/=]/, "base64url must not contain +, / or =");
  const message = decodeRaw(raw);
  assert.match(message, /^To: sam@example\.com\r\nSubject: Thursday\r\n/);
  assert.match(message, /Content-Type: text\/plain; charset="UTF-8"/);
  const body = message.split("\r\n\r\n")[1];
  assert.equal(Buffer.from(body, "base64").toString("utf8"), "See you at 3.");
});

test("non-ASCII subjects are RFC 2047 encoded", () => {
  const message = decodeRaw(buildRawMessage({ to: "a@b.co", subject: "Café ☕", body: "x" }));
  assert.match(message, /^To: a@b\.co\r\nSubject: =\?UTF-8\?B\?[A-Za-z0-9+/=]+\?=\r\n/);
});

test("draft validation mirrors the app's limits", () => {
  assert.deepEqual(
    validateDraft({ to: " Sam@Example.com ", subject: " Hi ", body: " Body " }),
    { to: "sam@example.com", subject: "Hi", body: "Body", mode: "send" },
  );
  assert.throws(() => validateDraft({ to: "not an email", subject: "s", body: "b" }), /invalid_recipient/);
  assert.throws(() => validateDraft({ to: "a@b.co", subject: "line\nbreak", body: "b" }), /invalid_subject/);
  assert.throws(() => validateDraft({ to: "a@b.co", subject: "s", body: "" }), /invalid_body/);
  assert.throws(() => validateDraft({ to: "a@b.co", subject: "s", body: "b", mode: "yolo" }), /invalid_mode/);
  assert.throws(() => validateDraft(null), /invalid_draft/);
});

test("configuration requires all three Google values", () => {
  assert.equal(gmailConfigured(env), true);
  assert.equal(gmailConfigured({ ...env, GMAIL_REFRESH_TOKEN: "" }), false);
});

test("authorization URL asks for offline access with the compose and read scopes and a bound state", () => {
  const url = new URL(authorizationURL({ clientId: "id", redirectUri: "https://x/cb", state: oauthState("t") }));
  assert.equal(url.searchParams.get("access_type"), "offline");
  assert.equal(url.searchParams.get("prompt"), "consent");
  assert.equal(
    url.searchParams.get("scope"),
    "https://www.googleapis.com/auth/gmail.compose https://www.googleapis.com/auth/gmail.readonly",
  );
  assert.equal(url.searchParams.get("state"), oauthState("t"));
  assert.equal(oauthState("t").length, 64);
});

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

test("send endpoint rejects a bad client token before touching Google", async () => {
  let upstreamCalls = 0;
  const res = fakeResponse();
  await handler(request({ auth: "Bearer nope", body: {} }), res, { env, fetch: async () => { upstreamCalls++; } });
  assert.equal(res.statusCode, 401);
  assert.equal(upstreamCalls, 0);
});

test("send endpoint reports when Gmail is not connected", async () => {
  const res = fakeResponse();
  await handler(request({ body: { to: "a@b.co", subject: "s", body: "b" } }), res, {
    env: { ...env, GMAIL_REFRESH_TOKEN: "" },
    fetch: async () => { throw new Error("must not be called"); },
  });
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.error, "gmail_not_configured");
});

test("send endpoint refreshes a token then posts the raw message", async () => {
  const calls = [];
  const doFetch = async (url, init) => {
    calls.push({ url, init });
    if (url.startsWith("https://oauth2.googleapis.com/token")) {
      return { ok: true, status: 200, json: async () => ({ access_token: "at" }) };
    }
    return { ok: true, status: 200, json: async () => ({ id: "msg-1" }) };
  };
  const res = fakeResponse();
  await handler(request({ body: { to: "sam@example.com", subject: "Hi", body: "Hello", mode: "draft" } }), res, { env, fetch: doFetch });

  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { ok: true, id: "msg-1", mode: "draft" });
  assert.equal(calls.length, 2);
  assert.equal(calls[1].url, "https://gmail.googleapis.com/gmail/v1/users/me/drafts");
  assert.equal(calls[1].init.headers.Authorization, "Bearer at");
  const payload = JSON.parse(calls[1].init.body);
  assert.match(decodeRaw(payload.message.raw), /^To: sam@example\.com/);
});

test("send endpoint maps upstream failures to 502 without leaking details", async () => {
  const doFetch = async (url) =>
    url.includes("/token")
      ? { ok: true, status: 200, json: async () => ({ access_token: "at" }) }
      : { ok: false, status: 403, json: async () => ({ error: "insufficient scope" }) };
  const res = fakeResponse();
  await handler(request({ body: { to: "a@b.co", subject: "s", body: "b" } }), res, { env, fetch: doFetch });
  assert.equal(res.statusCode, 502);
  assert.equal(res.body.error, "send_failed");
});
