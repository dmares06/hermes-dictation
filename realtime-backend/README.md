# WhisperDict Realtime backend

This Vercel service creates short-lived OpenAI Realtime WebRTC sessions for the personal WhisperDict iPhone app. The permanent OpenAI key never ships in the app.

## Required environment variables

- `OPENAI_API_KEY`: server-only OpenAI project API key
- `WHISPERDICT_CLIENT_TOKEN`: independent high-entropy token required from the personal iPhone app

Never prefix either value with `NEXT_PUBLIC_`, commit it, or paste it into app source.

## Endpoints

- `GET /api/health`: reports service and configuration state without revealing values
- `POST /api/realtime-session`: accepts an authenticated `application/sdp` WebRTC offer and returns OpenAI's SDP answer
- `POST /api/realtime-token`: returns an authenticated short-lived client secret for native WebRTC

The Realtime session uses `gpt-realtime-2.1`, the `marin` voice, low-eagerness semantic voice activity detection, and an allowlist of reviewable iPhone actions.

## Local verification

```bash
npm test
```
