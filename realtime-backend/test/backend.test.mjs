import assert from "node:assert/strict";
import test from "node:test";

import { authorized, safetyIdentifier } from "../lib/auth.mjs";
import { readSDPBody, SDPBodyError } from "../lib/request-body.mjs";
import { realtimeSession } from "../lib/session-config.mjs";
import realtimeSessionHandler from "../api/realtime-session.mjs";
import realtimeTokenHandler from "../api/realtime-token.mjs";

test("client authorization requires an exact bearer token", () => {
  assert.equal(authorized("Bearer personal-secret", "personal-secret"), true);
  assert.equal(authorized("Bearer wrong-secret", "personal-secret"), false);
  assert.equal(authorized(undefined, "personal-secret"), false);
  assert.equal(authorized("personal-secret", "personal-secret"), false);
  assert.equal(safetyIdentifier("personal-secret").length, 64);
});

test("session uses responsive semantic turn detection and a natural voice", () => {
  assert.equal(realtimeSession.model, "gpt-realtime-2.1");
  assert.equal(realtimeSession.audio.input.turn_detection.type, "semantic_vad");
  assert.equal(realtimeSession.audio.input.turn_detection.eagerness, "high");
  assert.equal(realtimeSession.audio.output.voice, "marin");
  assert.equal(realtimeSession.audio.output.speed, 1.08);
  assert.equal(realtimeSession.audio.input.transcription.model, "gpt-4o-mini-transcribe");
});

// The read-only tools run without asking the user, so which tools are in
// which group is a safety boundary, not a detail. Anything that acts on the
// user's behalf has to stay in the confirmed group.
const REVIEWED_TOOLS = [
  "prepare_message",
  "prepare_email",
  "send_email",
  "prepare_note",
  "save_note",
  "create_reminder",
  "open_destination",
  "run_shortcut",
];
const READ_ONLY_TOOLS = ["search_web", "search_notes", "list_reminders", "get_datetime"];

test("session exposes only the allowlisted actions", () => {
  assert.deepEqual(
    realtimeSession.tools.map((tool) => tool.name).sort(),
    [...REVIEWED_TOOLS, ...READ_ONLY_TOOLS].sort(),
  );
  assert.equal(realtimeSession.tool_choice, "auto");

  const openDestination = realtimeSession.tools.find(
    (tool) => tool.name === "open_destination",
  );
  assert.deepEqual(openDestination.parameters.properties.destination.enum, [
    "gmail",
    "settings",
    "maps",
    "calendar",
    "music",
    "youtube",
    "spotify",
  ]);
});

test("SDP parser accepts an offer and rejects invalid or oversized input", async () => {
  // The trailing CRLF has to survive: without it the upstream SDP parser
  // reports EOF on the last line and rejects the whole offer.
  assert.equal(await readSDPBody({ body: "v=0\r\no=- example" }), "v=0\r\no=- example\r\n");
  assert.equal(await readSDPBody({ body: "v=0\r\no=- example\r\n" }), "v=0\r\no=- example\r\n");
  assert.equal(await readSDPBody({ body: "  v=0\r\no=- example\r\n\r\n  " }), "v=0\r\no=- example\r\n");
  await assert.rejects(() => readSDPBody({ body: "not an offer" }), SDPBodyError);
  await assert.rejects(() => readSDPBody({ body: `v=0${"x".repeat(20)}` }, 10), SDPBodyError);
});

test("session endpoint rejects an invalid client token before checking the provider key", async () => {
  const previousClientToken = process.env.WHISPERDICT_CLIENT_TOKEN;
  const previousOpenAIKey = process.env.OPENAI_API_KEY;
  process.env.WHISPERDICT_CLIENT_TOKEN = "personal-secret";
  delete process.env.OPENAI_API_KEY;

  const response = mockResponse();
  try {
    await realtimeSessionHandler(
      {
        method: "POST",
        headers: {
          authorization: "Bearer wrong-secret",
          "content-type": "application/sdp",
        },
        body: "v=0\r\no=- example",
      },
      response,
    );
    assert.equal(response.statusCode, 401);
    assert.deepEqual(response.payload, { error: "unauthorized" });
  } finally {
    restoreEnvironment("WHISPERDICT_CLIENT_TOKEN", previousClientToken);
    restoreEnvironment("OPENAI_API_KEY", previousOpenAIKey);
  }
});

test("token endpoint returns only the short-lived client secret", async () => {
  const previousClientToken = process.env.WHISPERDICT_CLIENT_TOKEN;
  const previousOpenAIKey = process.env.OPENAI_API_KEY;
  const previousFetch = globalThis.fetch;
  process.env.WHISPERDICT_CLIENT_TOKEN = "personal-secret";
  process.env.OPENAI_API_KEY = "provider-secret";
  globalThis.fetch = async (_url, options) => {
    assert.equal(options.headers.Authorization, "Bearer provider-secret");
    return new Response(
      JSON.stringify({ value: "ek_test", expires_at: 1234, ignored: "server metadata" }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  };

  const response = mockResponse();
  try {
    await realtimeTokenHandler(
      { method: "POST", headers: { authorization: "Bearer personal-secret" } },
      response,
    );
    assert.equal(response.statusCode, 200);
    assert.deepEqual(response.payload, { value: "ek_test", expires_at: 1234 });
  } finally {
    globalThis.fetch = previousFetch;
    restoreEnvironment("WHISPERDICT_CLIENT_TOKEN", previousClientToken);
    restoreEnvironment("OPENAI_API_KEY", previousOpenAIKey);
  }
});

function mockResponse() {
  return {
    headers: {},
    payload: undefined,
    statusCode: 200,
    setHeader(name, value) {
      this.headers[name] = value;
    },
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(value) {
      this.payload = value;
      return this;
    },
    send(value) {
      this.payload = value;
      return this;
    },
  };
}

function restoreEnvironment(name, value) {
  if (value === undefined) {
    delete process.env[name];
  } else {
    process.env[name] = value;
  }
}

test("read-only tools take no action on the user's behalf", () => {
  // A tool that only reads may skip confirmation. One that writes, sends, or
  // opens something must not be in this group, whatever it is called.
  for (const name of READ_ONLY_TOOLS) {
    const tool = realtimeSession.tools.find((candidate) => candidate.name === name);
    assert.ok(tool, `${name} is missing from the session`);
    assert.match(tool.description, /without user confirmation/);
    assert.doesNotMatch(tool.name, /^(send|save|create|open|run|prepare)_/);
  }
});

test("every tool that acts still requires confirmation", () => {
  for (const name of REVIEWED_TOOLS) {
    const tool = realtimeSession.tools.find((candidate) => candidate.name === name);
    assert.ok(tool, `${name} is missing from the session`);
    assert.doesNotMatch(tool.description, /without user confirmation/);
  }
});

test("the model is told to verify current facts rather than guess", () => {
  assert.match(realtimeSession.instructions, /search_web/);
  assert.match(realtimeSession.instructions, /never state a fact you did not verify/i);
});
