# Voice-first Hermes — build notes and device test plan

Personal build. The goal is a phone you talk to: dictate anywhere without
leaving the app you are in, keep notes and reminders by voice, and have the
agent actually do things (starting with email) after a confirmation.

## What is built

### Phase 1 — Resident dictation (the Wispr Flow model)

Apple forbids keyboards from using the microphone, so every dictation
keyboard records in its *app*. The difference between "the app opens every
time" and "you never leave Messages" is only whether the app is already awake.

- After the first foreground use, a silent audio keepalive holds the process
  resident for a **listening window** (Settings → Background listening; 5 min
  default, like other dictation keyboards).
- While the window is open, three things start a recording *without* bringing
  the app forward: the keyboard's **Talk** button, the **Talk to WhisperDict**
  shortcut (assign it to the Action Button), and the mic button on the Live
  Activity. They write a request to the app group and post a Darwin
  notification; the resident app polls the request at 250 ms and the
  notification makes it immediate.
- The Live Activity starts while the app is visible (iOS refuses background
  starts) and is updated through idle → recording → transcribing → ready.
- `openAppWhenRun` must be a compile-time constant, so **Start Dictation**
  (always opens the app) and **Talk** (`ForegroundContinuableIntent`; silent
  when resident, one "continue" tap when not) are separate shortcuts.

Known costs: the keepalive uses some battery while the window is open; Low
Power Mode or a phone call can end residency, after which Talk falls back to
opening the app.

#### Dictation latency

The wait a user actually feels is model load + audio conversion + one encoder
pass + the decode loop. Each was addressed where it was payable:

- **Model load** is prewarmed when the listening window opens and again at
  record time, so it overlaps with speaking rather than following it. An
  in-flight load is joined, never restarted. `modelLoadingSeconds` in the
  latency record is the check: anything above zero means a prewarm was missed.
- **Audio conversion** is gone. The tap resamples to Whisper's 16 kHz mono as
  it captures, so stopping hands over a ready sample array — no file written
  during capture, no decode-and-resample pass afterwards.
- **Decoding** is tuned for dictation rather than media: the language is
  pinned, timestamp tokens are suppressed (nothing here reads them, and they
  are a large share of the tokens emitted for a short utterance), and
  temperature fallback is capped at one retry instead of five, which bounds
  what a noisy clip can cost. Past 30 s, VAD chunking decodes the pieces
  concurrently.
- **Delivery** no longer waits on the keyboard's 250 ms poll: the app posts a
  `transcriptReady` Darwin ping and the keyboard inserts on it.

The encoder pass is the floor and scales with model size — Whisper always
encodes a padded 30-second window, so a two-second clip costs the same
encode as a twenty-second one. Settings → Model is the lever there: `tiny`
and `base` are several times faster than `small` at some accuracy cost.

`./ios_run.sh --latency` prints where the last dictation's time went, read
back from the app group. Measure before changing anything.

### Phase 2 — Notes and reminders

- Notes live inside Hermes (Notes tab, search, edit). Every transcript has a
  **Note** action; the agent's default note action is `save_note`. Apple Notes
  is still reachable by name via the share sheet.
- Reminders go through EventKit into the Reminders app so they alert and
  sync. `ReminderParser` turns "remind me to call the dentist tomorrow at 9"
  into a title and due date; used by the transcript **Remind** action, the
  Notes tab, and the agent's `create_reminder`.

### Phase 3 — Gmail

- Backend: one-time OAuth (`/api/gmail-auth` → consent → `/api/gmail-callback`
  shows the refresh token once) and `/api/gmail-send` gated by the client
  token. Google credentials never leave the server. See
  `realtime-backend/README.md` for the four setup steps.
- App: Settings → Agent email → **Send with Gmail** turns a confirmed email
  into a real send; the default stays a Mail-app draft. Realtime's
  `send_email` tool is re-targeted to that preference before review.

### Phase 4 — Realtime voice

- The app authenticates to the backend with `WHISPERDICT_CLIENT_TOKEN`,
  expanded into Info.plist at build time. Nothing in the project supplied it,
  so every CLI build had shipped an empty token. `ios_run.sh` now injects it
  from `realtime-backend/.vercel/.env.production.local` (gitignored; the
  token was rotated because Vercel Sensitive values cannot be read back).
- Backend deployed with the new tools; `/api/health` reports `configured`
  and `gmail`.

## Device test plan

Phone unlocked and plugged in; `./ios_run.sh` builds, installs, launches.

1. **Cold start.** Open the app, allow the microphone, prepare the model.
   Dictate once in-app. A Live Activity reading "Ready to dictate" should
   remain after you leave the app.
2. **Resident dictation.** In Messages, open the WhisperDict keyboard; the
   main control should read **Talk**. Tap it, speak, tap **Stop**. Text should
   insert without the app appearing. Repeat with the Action Button (assigned
   to *Talk to WhisperDict*) and with the Live Activity mic button.
3. **Window expiry.** Wait past the configured window; the Live Activity ends
   and the keyboard control returns to **Action Button**. Talk from the
   shortcut should now ask to continue in the app.
4. **Interruption.** Take a phone call mid-window; afterwards Talk should fall
   back to opening the app rather than failing silently.
5. **Notes.** Dictate, tap **Note**; it appears in the Notes tab. Tell the
   agent "take a note", confirm; it saves in Hermes.
6. **Reminders.** Tap **Remind** on "call the dentist tomorrow at 9"; check
   the parsed title and time, add, and confirm it appears in the Reminders
   app with an alert. Ask the agent "remind me to…".
7. **Realtime.** Agent tab → start a conversation. It should connect (not
   fail with a missing client token) and respond aloud.
8. **Gmail** (after backend setup). Settings → Agent email → Send with Gmail.
   Ask the agent to send an email; review; confirm; check the Sent folder.
