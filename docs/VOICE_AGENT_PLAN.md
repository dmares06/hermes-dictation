# Hermes Voice Agent Plan

## Product outcome

Add a hands-free, conversational workspace to the iPhone app. One tap starts a foreground conversation: Hermes detects when the person finishes speaking, transcribes the turn on-device, responds aloud, and automatically listens again. It prepares only allowlisted actions and waits for a one-time confirmation before handing anything to another app.

The first release supports two complete journeys:

1. Compose an email by voice, review the recipient, subject, and body in Hermes, then open the draft in the iPhone's default mail app. Gmail is supported when the person sets Gmail as their default mail app.
2. Create a note by voice, review it in Hermes, then open the system share sheet and explicitly choose Notes.

Hermes also recognizes requests to open Gmail on the web and Settings. An "open Notes" request safely starts the create-note flow because iOS provides no public API for controlling the Notes app. Navigation actions still show what will happen before leaving Hermes.

## Platform boundary

iOS sandboxes third-party apps. Hermes cannot inspect Gmail or Notes, tap their controls, type into arbitrary fields, or keep a foreground voice conversation running after another app replaces it onscreen. The implementation must use public system handoff APIs instead of accessibility automation or private URL schemes.

The safe in-app interaction is therefore:

```text
tap once -> listen -> detect pause -> local transcript -> deterministic plan -> speak -> listen again
                                                        |
                                                        +-> visible review -> confirm once -> system handoff
```

The red Stop button ends the conversation at any point. A confirmed external handoff ends listening before iOS opens the destination. Hermes never sends an email or saves an Apple Note itself; the destination app presents its own final send or save control.

## MVP conversation model

### Start an email

- Person: "Compose an email."
- Hermes: "Who is it for?"
- Person speaks the recipient.
- Hermes asks for the subject, then the body.
- Hermes shows the full draft and reads a short summary.
- Person says "confirm" or taps **Open email draft**.
- Hermes opens a `mailto:` draft in the configured default mail app.

The recipient must parse as a bounded email address before the action can become confirmable. A draft is capped before URL construction so an accidental long transcript cannot create an oversized handoff URL.

### Start a note

- Person: "Create a note."
- Hermes asks what the note should say.
- Hermes shows the complete note and asks for confirmation.
- Person says "confirm" or taps **Share note**.
- Hermes presents the system share sheet. The person chooses Notes and completes the save there.

### Cancel or correct

- "Cancel", "never mind", and the Cancel button discard the pending action.
- "Start over" resets the current draft without executing it.
- A rejected, malformed, or unsupported request produces an explanation and safe examples. It never falls through to a guessed action.

## Architecture

### `WhisperDictCore`

- `VoiceAgentSession`: deterministic, testable state machine for multi-turn collection, validation, pending approvals, cancellation, and one-time action consumption.
- `VoiceTurnDetector`: deterministic speech/silence timing that completes a spoken turn after sustained speech and an end pause, while ignoring brief noise and stopping an idle session.
- `VoiceAgentAction`: a small allowlist of external effects: open a public URL, prepare a mail draft, or share note text.
- No network client, secret, arbitrary tool name, reflection, shell command, or model-generated URL exists in the executor path.

### iOS app

- `VoiceAgentController`: keeps the one-tap foreground conversation loop alive, records with the existing local recorder, transcribes with the existing Whisper model, feeds text into `VoiceAgentSession`, speaks responses with `AVSpeechSynthesizer`, and resumes listening.
- `VoiceAgentView`: conversation transcript, recording state, draft preview, and explicit confirm/cancel controls.
- The controller's closed action executor converts only validated action values into `UIApplication.open` or a system share sheet.
- `ContentView`: keeps dictation intact and adds an Agent tab.

## Security requirements

- Treat every transcript as untrusted input.
- Parse into closed Swift enums and bounded value types; never execute free-form tool output.
- Display the exact pending recipient, subject, body, note, or destination before confirmation.
- Require a pending action owned by the current in-memory session.
- Consume approval once, before attempting the external handoff; replaying confirm does nothing.
- Require explicit confirmation for all external handoffs, including navigation.
- Encode mail fields with `URLComponents`; never concatenate untrusted input into a URL.
- Do not log or persist email recipients, subjects, bodies, notes, or spoken responses.
- Stop recording when the app leaves the foreground.
- Keep all speech recognition on-device with the existing WhisperKit path.

## Test plan

- Unit tests for every conversation transition and supported phrase.
- Unit tests for speech onset, brief noise, end-of-turn silence, renewed speech, reset, and idle timeout.
- Validation tests for malformed addresses, missing fields, maximum lengths, cancellation, unsupported commands, and confirmation replay.
- URL-construction tests for reserved characters and injection-like input.
- Existing transcript, storage, appearance, and keyboard tests remain green.
- Unsigned generic-iOS build passes.
- Dependency, tracked-secret, and diff security scans pass.
- Physical-device acceptance remains a release prerequisite: microphone permission, local transcription, spoken feedback, default Gmail handoff, Mail fallback, and Add to Notes share flow.

## Out of scope for this PR

- Sending email without the mail app's own Send action.
- Writing directly into Apple Notes.
- Reading inboxes, notes, contacts, or screen contents.
- Controlling another app after Hermes leaves the foreground.
- Background hotword listening.
- Simultaneous full-duplex speech or interrupting Hermes while it is speaking; this release uses automatic alternating turns.
- Cloud LLM planning or downloadable executable tools.

## Future expansion

Add capabilities one at a time behind the same typed action and approval boundary. Public App Intents and user-authored Shortcuts are the preferred path for deeper system workflows. A later cloud planner may propose typed actions, but the local executor must continue to validate, preview, and require one-time user approval independently.
