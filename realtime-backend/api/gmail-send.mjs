import { authorized } from "../lib/auth.mjs";
import { accessToken, buildRawMessage, deliver, GmailError, gmailConfigured, validateDraft } from "../lib/gmail.mjs";
import { JSONBodyError, readJSONBody } from "../lib/json-body.mjs";

/**
 * Sends (or drafts) one email from the connected Gmail account.
 *
 * The phone never sees Google credentials: it presents the same client token
 * as the Realtime endpoint, and the server holds the refresh token.
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

  let draft;
  try {
    draft = validateDraft(await readJSONBody(request));
  } catch (error) {
    if (error instanceof JSONBodyError) {
      return response.status(error.code === "too_large" ? 413 : 400).json({ error: error.code });
    }
    if (error instanceof GmailError) return response.status(400).json({ error: error.code });
    return response.status(400).json({ error: "invalid_draft" });
  }

  try {
    const token = await accessToken({
      clientId: env.GOOGLE_CLIENT_ID,
      clientSecret: env.GOOGLE_CLIENT_SECRET,
      refreshToken: env.GMAIL_REFRESH_TOKEN,
      fetch: doFetch,
    });
    const result = await deliver({ token, raw: buildRawMessage(draft), mode: draft.mode, fetch: doFetch });
    return response.status(200).json({ ok: true, ...result });
  } catch (error) {
    const code = error instanceof GmailError ? error.code : "gmail_unavailable";
    console.error("Gmail delivery failed", code, error?.upstreamStatus ?? "");
    return response.status(502).json({ error: code });
  }
}
