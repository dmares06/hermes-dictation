import { createHash } from "node:crypto";

const AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const GMAIL_URL = "https://gmail.googleapis.com/gmail/v1/users/me";
// gmail.compose covers creating drafts and sending. gmail.readonly is what
// lets Hermes answer "what did Sam say about Friday" and reply in context; it
// is a read of the mailbox, so it is granted deliberately rather than as a
// side effect of the send scope. Adding it means re-running /api/gmail-auth:
// a refresh token issued before the scope existed cannot use it.
export const SCOPES = Object.freeze([
  "https://www.googleapis.com/auth/gmail.compose",
  "https://www.googleapis.com/auth/gmail.readonly",
]);
export const SCOPE = SCOPES.join(" ");

export const LIMITS = Object.freeze({
  recipient: 254,
  subject: 200,
  body: 4_000,
  query: 200,
  messages: 10,
  snippet: 300,
});

export function gmailConfigured(env = process.env) {
  return Boolean(env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET && env.GMAIL_REFRESH_TOKEN);
}

/** Ties the OAuth round-trip to this deployment's client token without exposing it. */
export function oauthState(clientToken) {
  return createHash("sha256").update(`whisperdict:gmail:${clientToken}`).digest("hex");
}

export function authorizationURL({ clientId, redirectUri, state }) {
  const url = new URL(AUTH_URL);
  url.searchParams.set("client_id", clientId);
  url.searchParams.set("redirect_uri", redirectUri);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", SCOPE);
  // offline + consent is what makes Google return a refresh token.
  url.searchParams.set("access_type", "offline");
  url.searchParams.set("prompt", "consent");
  url.searchParams.set("state", state);
  return url.toString();
}

export async function exchangeCode({ code, clientId, clientSecret, redirectUri, fetch: doFetch = fetch }) {
  const response = await doFetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: clientId,
      client_secret: clientSecret,
      redirect_uri: redirectUri,
      grant_type: "authorization_code",
    }),
    signal: AbortSignal.timeout(15_000),
  });
  const json = await response.json();
  if (!response.ok || !json.refresh_token) {
    throw new GmailError("token_exchange_failed", response.status);
  }
  return json.refresh_token;
}

export async function accessToken({ clientId, clientSecret, refreshToken, fetch: doFetch = fetch }) {
  const response = await doFetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    }),
    signal: AbortSignal.timeout(15_000),
  });
  const json = await response.json();
  if (!response.ok || !json.access_token) {
    throw new GmailError("token_refresh_failed", response.status);
  }
  return json.access_token;
}

/**
 * Validates a draft the way the app does, so the server never trusts the
 * client's checks alone.
 */
export function validateDraft(input) {
  if (!input || typeof input !== "object") throw new GmailError("invalid_draft");
  const { to, subject, body, mode = "send" } = input;
  if (typeof to !== "string" || typeof subject !== "string" || typeof body !== "string") {
    throw new GmailError("invalid_draft");
  }
  const recipient = to.trim().toLowerCase();
  if (
    recipient.length === 0 ||
    recipient.length > LIMITS.recipient ||
    !/^[^\s@,;:<>()[\]\\"]+@[^\s@,;:<>()[\]\\"]+\.[^\s@,;:<>()[\]\\".]+$/.test(recipient)
  ) {
    throw new GmailError("invalid_recipient");
  }
  const cleanSubject = subject.trim();
  const cleanBody = body.trim();
  if (cleanSubject.length === 0 || cleanSubject.length > LIMITS.subject) throw new GmailError("invalid_subject");
  if (cleanBody.length === 0 || cleanBody.length > LIMITS.body) throw new GmailError("invalid_body");
  if (/[\r\n]/.test(cleanSubject)) throw new GmailError("invalid_subject");
  if (mode !== "send" && mode !== "draft") throw new GmailError("invalid_mode");
  return { to: recipient, subject: cleanSubject, body: cleanBody, mode };
}

/** RFC 2822 message, base64url-encoded the way Gmail's `raw` field wants. */
export function buildRawMessage({ to, subject, body }) {
  const encodedSubject = /^[\x20-\x7e]*$/.test(subject)
    ? subject
    : `=?UTF-8?B?${Buffer.from(subject, "utf8").toString("base64")}?=`;
  const message = [
    `To: ${to}`,
    `Subject: ${encodedSubject}`,
    "MIME-Version: 1.0",
    'Content-Type: text/plain; charset="UTF-8"',
    "Content-Transfer-Encoding: base64",
    "",
    Buffer.from(body, "utf8").toString("base64"),
  ].join("\r\n");
  return Buffer.from(message, "utf8").toString("base64url");
}

export async function deliver({ token, raw, mode, fetch: doFetch = fetch }) {
  const url = mode === "draft" ? `${GMAIL_URL}/drafts` : `${GMAIL_URL}/messages/send`;
  const payload = mode === "draft" ? { message: { raw } } : { raw };
  const response = await doFetch(url, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
    signal: AbortSignal.timeout(20_000),
  });
  const json = await response.json().catch(() => ({}));
  if (!response.ok) throw new GmailError(mode === "draft" ? "draft_failed" : "send_failed", response.status);
  return { id: json.id ?? null, mode };
}

export class GmailError extends Error {
  constructor(code, upstreamStatus) {
    super(code);
    this.name = "GmailError";
    this.code = code;
    this.upstreamStatus = upstreamStatus;
  }
}

/**
 * Validates a mailbox lookup. An empty query means "the most recent mail",
 * which is what "read me my email" asks for.
 */
export function validateLookup(input) {
  const source = input && typeof input === "object" ? input : {};
  const { query = "", limit } = source;
  if (typeof query !== "string") throw new GmailError("invalid_query");
  const cleanQuery = query.trim();
  if (cleanQuery.length > LIMITS.query) throw new GmailError("query_too_long");
  if (/[\r\n]/.test(cleanQuery)) throw new GmailError("invalid_query");
  const requested = limit === undefined ? 5 : Number(limit);
  if (!Number.isFinite(requested) || requested < 1) throw new GmailError("invalid_limit");
  return { query: cleanQuery, limit: Math.min(Math.trunc(requested), LIMITS.messages) };
}

function header(payload, name) {
  const headers = payload?.headers ?? [];
  const match = headers.find((entry) => entry?.name?.toLowerCase() === name);
  return typeof match?.value === "string" ? match.value : "";
}

/** Decodes the entities Gmail's snippets carry, so speech does not read them out. */
function decodeSnippet(value) {
  return String(value ?? "")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, LIMITS.snippet);
}

/**
 * Lists recent messages and returns only what a spoken answer needs:
 * who it is from, the subject, when, and Gmail's own snippet. Bodies and
 * attachments are never fetched.
 */
export async function listMessages({ token, query, limit, fetch: doFetch = fetch }) {
  const listURL = new URL(`${GMAIL_URL}/messages`);
  listURL.searchParams.set("maxResults", String(limit));
  // Without a query this is the inbox rather than every archived thread.
  listURL.searchParams.set("q", query || "in:inbox newer_than:7d");

  const listResponse = await doFetch(listURL.toString(), {
    headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(15_000),
  });
  if (!listResponse.ok) {
    throw new GmailError(listResponse.status === 403 ? "insufficient_scope" : "search_failed", listResponse.status);
  }
  const listing = await listResponse.json().catch(() => ({}));
  const ids = (listing.messages ?? []).map((message) => message?.id).filter(Boolean).slice(0, limit);

  const messages = await Promise.all(
    ids.map(async (id) => {
      const detailURL = new URL(`${GMAIL_URL}/messages/${encodeURIComponent(id)}`);
      detailURL.searchParams.set("format", "metadata");
      for (const name of ["From", "Subject", "Date"]) {
        detailURL.searchParams.append("metadataHeaders", name);
      }
      const response = await doFetch(detailURL.toString(), {
        headers: { Authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(15_000),
      });
      if (!response.ok) return null;
      const message = await response.json().catch(() => null);
      if (!message) return null;
      return {
        id: message.id ?? id,
        from: header(message.payload, "from"),
        subject: header(message.payload, "subject") || "(no subject)",
        date: header(message.payload, "date"),
        snippet: decodeSnippet(message.snippet),
      };
    }),
  );

  return messages.filter(Boolean);
}
