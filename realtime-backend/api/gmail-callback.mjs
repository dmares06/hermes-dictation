import { timingSafeEqual } from "node:crypto";
import { exchangeCode, oauthState } from "../lib/gmail.mjs";

/**
 * Google redirects here after consent. The refresh token is shown once, in
 * the browser, for the operator to paste into the GMAIL_REFRESH_TOKEN env
 * var — it is never logged or stored by this function.
 */
export default async function handler(request, response) {
  const clientToken = process.env.WHISPERDICT_CLIENT_TOKEN;
  const clientId = process.env.GOOGLE_CLIENT_ID;
  const clientSecret = process.env.GOOGLE_CLIENT_SECRET;
  const redirectUri = process.env.GOOGLE_REDIRECT_URI;
  if (!clientToken || !clientId || !clientSecret || !redirectUri) {
    return response.status(503).json({ error: "service_not_configured" });
  }

  const { code, state, error } = request.query ?? {};
  if (error) return response.status(400).send(page("Google reported an error", String(error)));
  if (typeof code !== "string" || typeof state !== "string") {
    return response.status(400).send(page("Missing code", "Start again from /api/gmail-auth."));
  }
  const expected = Buffer.from(oauthState(clientToken));
  const supplied = Buffer.from(state);
  if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) {
    return response.status(400).send(page("State mismatch", "Start again from /api/gmail-auth."));
  }

  try {
    const refreshToken = await exchangeCode({ code, clientId, clientSecret, redirectUri });
    response.setHeader("Content-Type", "text/html; charset=utf-8");
    return response.status(200).send(
      page(
        "Gmail connected",
        `<p>Add this to the Vercel project as <code>GMAIL_REFRESH_TOKEN</code>, then redeploy:</p>
         <pre style="white-space:pre-wrap;word-break:break-all">${escapeHTML(refreshToken)}</pre>
         <p>This page is the only place the token appears. Close it when done.</p>`,
      ),
    );
  } catch {
    return response.status(502).send(page("Token exchange failed", "Check the client id, secret, and redirect URI, then try again."));
  }
}

function page(title, bodyHTML) {
  return `<!doctype html><meta charset="utf-8"><meta name="robots" content="noindex">
<title>${escapeHTML(title)}</title>
<body style="font-family:-apple-system,system-ui,sans-serif;max-width:40rem;margin:3rem auto;padding:0 1rem">
<h1>${escapeHTML(title)}</h1>${bodyHTML}</body>`;
}

function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}
