import { authorized } from "../lib/auth.mjs";
import { authorizationURL, oauthState } from "../lib/gmail.mjs";

/**
 * One-time setup, run from a browser: `/api/gmail-auth?token=<client token>`.
 * Redirects to Google's consent screen; the callback shows the refresh token.
 */
export default async function handler(request, response) {
  const clientToken = process.env.WHISPERDICT_CLIENT_TOKEN;
  const clientId = process.env.GOOGLE_CLIENT_ID;
  const redirectUri = process.env.GOOGLE_REDIRECT_URI;
  if (!clientToken || !clientId || !redirectUri) {
    return response.status(503).json({ error: "service_not_configured" });
  }
  const supplied = request.query?.token;
  if (!authorized(`Bearer ${supplied ?? ""}`, clientToken)) {
    return response.status(401).json({ error: "unauthorized" });
  }
  response.setHeader("Location", authorizationURL({ clientId, redirectUri, state: oauthState(clientToken) }));
  return response.status(302).end();
}
