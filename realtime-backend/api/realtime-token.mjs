import { authorized, safetyIdentifier } from "../lib/auth.mjs";
import { realtimeSession } from "../lib/session-config.mjs";

export default async function handler(request, response) {
  if (request.method !== "POST") {
    response.setHeader("Allow", "POST");
    return response.status(405).json({ error: "method_not_allowed" });
  }

  const clientToken = process.env.WHISPERDICT_CLIENT_TOKEN;
  if (!clientToken) {
    return response.status(503).json({ error: "service_not_configured" });
  }
  if (!authorized(request.headers.authorization, clientToken)) {
    return response.status(401).json({ error: "unauthorized" });
  }

  const openAIKey = process.env.OPENAI_API_KEY;
  if (!openAIKey) {
    return response.status(503).json({ error: "service_not_configured" });
  }

  try {
    const upstream = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${openAIKey}`,
        "Content-Type": "application/json",
        "OpenAI-Safety-Identifier": safetyIdentifier(clientToken),
      },
      body: JSON.stringify({ session: realtimeSession }),
      signal: AbortSignal.timeout(15_000),
    });
    const data = await upstream.json().catch(() => ({}));
    if (!upstream.ok || typeof data.value !== "string") {
      console.error("OpenAI Realtime token failed", upstream.status, JSON.stringify(data).slice(0, 500));
      return response.status(502).json({ error: "realtime_token_failed" });
    }

    return response.status(200).json({ value: data.value, expires_at: data.expires_at });
  } catch (error) {
    console.error("OpenAI Realtime token request failed", error instanceof Error ? error.message : "unknown");
    return response.status(502).json({ error: "realtime_unavailable" });
  }
}
