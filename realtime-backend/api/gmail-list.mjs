import { authorized } from "../lib/auth.mjs";
import { accessToken, GmailError, gmailConfigured, listMessages, validateLookup } from "../lib/gmail.mjs";
import { JSONBodyError, readJSONBody } from "../lib/json-body.mjs";

/**
 * Reads recent mail from the connected Gmail account.
 *
 * Returns headers and Gmail's own snippet only — never message bodies or
 * attachments — which is enough for Hermes to answer a spoken question or
 * reply in context, and keeps the amount of mailbox leaving Google small.
 */
export default async function handler(request, response, deps = {}) {
  const env = deps.env ?? process.env;
  const doFetch = deps.fetch ?? fetch;

  if (request.method !== "POST") {
    response.setHeader("Allow", "POST");
    return response.status(405).json({ error: "method_not_allowed" });
  }
  const clientToken = env.WHISPERDICT_CLIENT_TOKEN;
  if (!clientToken) return response.status(503).json({ error: "service_not_configured" });
  if (!authorized(request.headers.authorization, clientToken)) {
    return response.status(401).json({ error: "unauthorized" });
  }
  if (!gmailConfigured(env)) return response.status(503).json({ error: "gmail_not_configured" });

  let lookup;
  try {
    lookup = validateLookup(await readJSONBody(request));
  } catch (error) {
    if (error instanceof JSONBodyError) {
      return response.status(error.code === "too_large" ? 413 : 400).json({ error: error.code });
    }
    if (error instanceof GmailError) return response.status(400).json({ error: error.code });
    return response.status(400).json({ error: "invalid_query" });
  }

  try {
    const token = await accessToken({
      clientId: env.GOOGLE_CLIENT_ID,
      clientSecret: env.GOOGLE_CLIENT_SECRET,
      refreshToken: env.GMAIL_REFRESH_TOKEN,
      fetch: doFetch,
    });
    const messages = await listMessages({ token, ...lookup, fetch: doFetch });
    return response.status(200).json({ ok: true, messages });
  } catch (error) {
    const code = error instanceof GmailError ? error.code : "gmail_unavailable";
    console.error("Gmail lookup failed", code, error?.upstreamStatus ?? "");
    return response.status(code === "insufficient_scope" ? 403 : 502).json({ error: code });
  }
}
