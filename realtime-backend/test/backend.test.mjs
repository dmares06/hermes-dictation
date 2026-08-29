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
  assert.equal(realtimeSession.audio.input.turn_detection.eagerness, "low");
  assert.equal(realtimeSession.audio.output.voice, "marin");
  assert.equal(realtimeSession.audio.output.speed, 1.08);
  assert.equal(realtimeSession.audio.input.transcription.model, "gpt-4o-mini-transcribe");
});

// Realtime is the ears and the mouth; Hermes Agent on the Mac is the only
// brain. The session therefore exposes exactly one tool, and every phone
// action (messages, email, notes, reminders, opening apps) arrives inside
// Hermes's reply, where the app validates it and asks for confirmation.
test("the session's only tool relays the user's words to Hermes", () => {
  assert.deepEqual(realtimeSession.tools.map((tool) => tool.name), ["ask_hermes"]);
  assert.equal(realtimeSession.tool_choice, "auto");

  const [askHermes] = realtimeSession.tools;
  assert.equal(askHermes.type, "function");
  assert.deepEqual(askHermes.parameters.required, ["request"]);
  assert.equal(askHermes.parameters.properties.request.type, "string");
  assert.equal(askHermes.parameters.additionalProperties, false);
  assert.match(askHermes.description, /word for word/i);
});

test("the voice never answers on its own or claims an action happened", () => {
  const { instructions } = realtimeSession;
  assert.match(instructions, /never answer on your own/i);
  assert.match(instructions, /word for word/i);
  assert.match(instructions, /confirm or cancel/i);
  assert.match(instructions, /do not claim/i);
  assert.match(instructions, /ask_hermes/);
  // The user asked for answers, not narration: the voice must wait in
  // silence rather than announce that it is checking or still working.
  assert.match(instructions, /call the function silently/i);
  assert.match(instructions, /never announce that you are checking/i);
  assert.doesNotMatch(instructions, /words of acknowledgement/i);
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
