# WhisperDict Realtime backend

This Vercel service creates short-lived OpenAI Realtime WebRTC sessions for the personal WhisperDict iPhone app. The permanent OpenAI key never ships in the app.

## Required environment variables

- `OPENAI_API_KEY`: server-only OpenAI project API key
- `WHISPERDICT_CLIENT_TOKEN`: independent high-entropy token required from the personal iPhone app

Never prefix either value with `NEXT_PUBLIC_`, commit it, or paste it into app source.

## Gmail (optional)

Lets the app send email from your own Gmail account through the official API — no browser automation, no stored password. One-time setup:

1. In Google Cloud, enable the **Gmail API** and create an OAuth client of type **Web application** with the authorized redirect URI `https://<deployment>.vercel.app/api/gmail-callback`. If the consent screen is in *Testing*, add your Google account as a test user.
2. Set `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, and `GOOGLE_REDIRECT_URI` on the Vercel project and redeploy.
3. In a browser, open `https://<deployment>.vercel.app/api/gmail-auth?token=<WHISPERDICT_CLIENT_TOKEN>` and approve. The callback page shows a refresh token once.
4. Set `GMAIL_REFRESH_TOKEN` to that value and redeploy. `GET /api/health` now reports `"gmail": true`.

The scopes are `gmail.compose` (create drafts and send) and `gmail.readonly`, which is what lets Hermes answer questions about mail you have received and gather context before drafting a reply. Reads return headers and Gmail's own snippet only — message bodies and attachments are never fetched.

If you connected Gmail before the read scope existed, re-run steps 3 and 4: a refresh token issued for the old scopes cannot read, and `/api/gmail-list` answers `403 insufficient_scope` until you do.

## Endpoints

- `GET /api/health`: reports service and configuration state without revealing values
- `POST /api/realtime-session`: accepts an authenticated `application/sdp` WebRTC offer and returns OpenAI's SDP answer
- `POST /api/realtime-token`: returns an authenticated short-lived client secret for native WebRTC
- `POST /api/gmail-send`: authenticated JSON `{to, subject, body, mode: "send" | "draft"}`; sends or drafts through the connected Gmail account
- `POST /api/gmail-list`: authenticated JSON `{query, limit}`; returns `{ok, messages: [{id, from, subject, date, snippet}]}` for a Gmail search (empty query means the past week's inbox)
- `GET /api/gmail-auth?token=…` and `GET /api/gmail-callback`: one-time OAuth setup (see above)

The Realtime session uses `gpt-realtime-2.1`, the `marin` voice, low-eagerness semantic voice activity detection, and an allowlist of reviewable iPhone actions.

## Local verification

```bash
npm test
```
