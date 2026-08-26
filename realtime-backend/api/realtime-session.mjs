import { authorized, safetyIdentifier } from "../lib/auth.mjs";
import { readSDPBody, SDPBodyError } from "../lib/request-body.mjs";
import { realtimeSession } from "../lib/session-config.mjs";

export default async function handler(request, response) {
  if (request.method !== "POST") {
    response.setHeader("Allow", "POST");
    return response.status(405).json({ error: "method_not_allowed" });
  }

  const openAIKey = process.env.OPENAI_API_KEY;
  const clientToken = process.env.WHISPERDICT_CLIENT_TOKEN;
  if (!clientToken) {
    return response.status(503).json({ error: "service_not_configured" });
  }
  if (!authorized(request.headers.authorization, clientToken)) {
    return response.status(401).json({ error: "unauthorized" });
  }
  if (!openAIKey) {
    return response.status(503).json({ error: "service_not_configured" });
  }
  if (!String(request.headers["content-type"] ?? "").startsWith("application/sdp")) {
    return response.status(415).json({ error: "content_type_must_be_application_sdp" });
  }

  let sdp;
  try {
    sdp = await readSDPBody(request);
  } catch (error) {
    if (error instanceof SDPBodyError) {
      return response.status(error.code === "too_large" ? 413 : 400).json({ error: error.code });
    }
    return response.status(400).json({ error: "invalid_sdp" });
  }

  const form = new FormData();
  form.set("sdp", sdp);
  form.set("session", JSON.stringify(realtimeSession));

  try {
    const upstream = await fetch("https://api.openai.com/v1/realtime/calls", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${openAIKey}`,
        "OpenAI-Safety-Identifier": safetyIdentifier(clientToken),
      },
      body: form,
      signal: AbortSignal.timeout(25_000),
    });
    const body = await upstream.text();
    if (!upstream.ok) {
      console.error("OpenAI Realtime session failed", upstream.status, body.slice(0, 500));
      return response.status(502).json({ error: "realtime_session_failed" });
    }

    response.setHeader("Content-Type", "application/sdp");
    return response.status(200).send(body);
  } catch (error) {
    console.error("OpenAI Realtime request failed", error instanceof Error ? error.message : "unknown");
    return response.status(502).json({ error: "realtime_unavailable" });
  }
}
