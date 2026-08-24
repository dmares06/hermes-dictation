# 🎙️ Hermes Dictation

Local Whisper-powered push-to-talk dictation for macOS.
Drop-in replacement for **Wispr Flow** ($15/mo → $0/mo).

Hold a key → speak → release → text appears at your cursor.

## Quick Start

```bash
cd ~/hermes-dictation
./run.sh
```

Hold **Fn / Globe (🌐)** → speak → release. Text appears wherever your cursor is.

## Features

| Feature | Hermes Dictation | Wispr Flow ($15/mo) |
|---|---|---|
| Push-to-talk dictation | ✅ Hold ⌥, speak, release | ✅ |
| Local Whisper transcription | ✅ Runs entirely offline | ❌ Cloud-based |
| Filler word removal | ✅ "um, like, uh" auto-removed | ✅ |
| Auto-capitalize + punctuation | ✅ | ✅ |
| Works in any app | ✅ Types at cursor (Cmd+V) | ✅ |
| macOS menubar app | ✅ | ✅ |
| Model selection | ✅ tiny → large-v3 | ✅ |
| Hotkey selection | ✅ alt_r, f5, caps_lock, etc. | ✅ |
| Local transcript history + usage dashboard | ✅ Hermes Hub | ✅ |
| Local snippets + Scratchpad | ✅ | ✅ |
| **Cost** | **$0/mo** | **$15/mo** |
| **Privacy** | **100% offline** | **Audio sent to cloud** |

## Installation

### One-time setup

```bash
cd ~/hermes-dictation

# Create virtual environment with all dependencies
python3 -m venv venv
source venv/bin/activate
pip install faster-whisper mlx-whisper sounddevice pynput pyperclip pyobjc numpy

# Run it
./run.sh
# or:
python3 dictate.py
```

### macOS .app bundle (Launchpad-ready)

```bash
cd ~/hermes-dictation
chmod +x build_app.sh
./build_app.sh
cp -r dist/Hermes\ Dictation.app /Applications/
open /Applications/Hermes\ Dictation.app
```

## Usage

1. Launch the app — it lives in your menubar (🎙️)
2. Hold your chosen hotkey (default: **Fn / Globe 🌐**)
3. Speak naturally — it handles filler words, pauses, punctuation
4. Release the key — transcribed text appears at your cursor

While Whisper is working, Hermes shows a small floating transcription pill
near the bottom of the screen. On Apple Silicon, Hermes automatically uses
MLX Whisper to run transcription through Apple's Metal stack; faster-whisper
remains the fallback. The default English-specialized `small` model favors
dictation accuracy, while Fast transcription mode favors quicker cursor
insertion. The first launch downloads its local model and later launches use
the cached copy. Quality mode remains available in Hermes Hub under Settings
when you want the highest-confidence decoding for difficult audio.

## Hermes Hub

Hermes automatically opens **Hermes Hub** when the app launches. You can also
open it from the menubar menu. Its normal bookmarkable address is
`http://127.0.0.1:8765/`. It is a local-only dashboard with:

- monthly and all-time word counts, sessions, average WPM, and recent activity
- searchable transcript history saved in local SQLite
- snippets such as “my LinkedIn” that open a saved `https://` URL or insert text
- a Scratchpad for notes and unfinished ideas
- shortcut, model, quality/fast mode, filler cleanup, punctuation, and pause settings

The Hub server listens only on `127.0.0.1`. Its database is stored at
`~/.local/share/hermes-dictation/hermes.db`; no account or cloud service is
required.

Works in: any text field, any app — VS Code, Cursor, Chrome, Messages, Slack, Notes, etc.

## Configuration

All settings are in `~/.config/hermes-dictation/config.json`.

### Hotkey options

| Setting | Key |
|---|---|
| `fn` | Fn / Globe (🌐) — default |
| `alt_r` | Right Option (⌥) |
| `alt_l` | Left Option (⌥) |
| `f5` | F5 |
| `f6` | F6 |
| `caps_lock` | Caps Lock |

### Model options

| Model | Accuracy | RAM | Speed |
|---|---|---|---|
| `tiny` | Good | ~500MB | Fastest |
| `base` | Better | ~1.5GB | Fast |
| `small` | Great | ~3GB | Medium |
| `medium` | Excellent | ~6GB | Slow |
| `large-v3` | Best | ~10GB | Slowest |

## Permissions

The app needs two permissions on first run:

1. **Microphone** — System Settings > Privacy & Security > Microphone
2. **Accessibility** — System Settings > Privacy & Security > Accessibility *(for typing at cursor)*

## Architecture

```
┌─────────────────────────────────────┐
│       macOS Menubar App             │
│  (NSStatusBar + NSApplication)      │
├─────────────────────────────────────┤
│  DictationEngine                     │
│  ├─ Hotkey listener (pynput)        │
│  ├─ Audio capture (sounddevice)     │
│  ├─ Transcription (faster-whisper)  │
│  ├─ Text cleanup (regex)            │
│  └─ Typing (Quartz CGEvent / Cmd+V) │
└─────────────────────────────────────┘
```

## Files

| File | Purpose |
|---|---|
| `dictate.py` | Main app — menubar + dictation engine |
| `hermes_hub.py` | Loopback-only dashboard and local API |
| `hermes_store.py` | SQLite transcripts, snippets, notes, and stats |
| `test_hermes_store.py` | Local persistence tests |
| `smoke_test.py` | Automated smoke tests |
| `run.sh` | Launcher script (creates venv if needed) |
| `build_app.sh` | Build macOS .app bundle |
| `~/.config/hermes-dictation/config.json` | Persistent config |
| `~/.cache/whisper/` and `~/.cache/huggingface/` | Whisper model caches |

## iOS app

The iOS project is in `WhisperDict.xcodeproj/`. It contains:

- `WhisperDict` — records from the iPhone microphone, transcribes locally with WhisperKit, removes configurable filler words, and keeps recent transcripts
- `WhisperDictKeyboard` — a lightweight QWERTY/numeric keyboard that can insert the latest transcript from the app
- `Hermes Agent` — a one-tap conversational tab that detects the end of each spoken turn, answers aloud, listens again, and waits for explicit approval before external handoffs
- WhisperKit 1.x — on-device Core ML transcription

### iPhone workflow

1. Open WhisperDict and prepare the selected model. `Small` is the default for the best available accuracy in this build.
2. Tap the microphone, speak naturally, and tap Stop. The app writes audio to a temporary file so long recordings do not accumulate in RAM.
3. Assign the **Start Dictation** WhisperDict shortcut to your iPhone Action Button in Settings → Action Button → Shortcut.
4. In another app, switch to the WhisperDict keyboard and press the physical Action Button. WhisperDict opens and starts recording; speak naturally, then tap **Stop**, press the Action Button again, or use the Live Activity Stop button. Return to the original app and tap the keyboard's insert button to insert only that new transcript.

The recorder handles denied microphone permission, audio-session interruptions, disconnected audio routes, app backgrounding, missing models, and idle-time memory pressure. Transcript cleanup preserves meaningful uses such as “I like pizza” while removing hesitation sounds and clearly delimited filler phrases.

### Voice agent workflow

Tap the Agent microphone once to start. Speak naturally and pause when a turn is complete; Hermes transcribes locally, answers aloud, then starts listening for the next turn automatically. Tap the red Stop button to end the conversation. This is automatic alternating turn-taking, not simultaneous full-duplex audio.

The **Agent** tab supports these on-device conversations:

- “Compose an email” → speak one recipient, a subject, and the body → review the exact draft → say **confirm** or tap **Open email draft**
- “Create a note” → speak the note → review it → say **confirm** or tap **Share note**, then choose Notes
- “Open Gmail” or “Open Settings” → review the destination → confirm before leaving Hermes

Email uses the iPhone's default mail app, so set Gmail as the default mail app if you want drafts to open there. Hermes never presses Send or saves a note itself. iOS does not let third-party apps inspect or control another app's interface; the conversation stays in Hermes until a standard system handoff opens, and listening ends before that handoff.

The typed action model, approval rules, security boundaries, test plan, and future expansion path are documented in [`docs/VOICE_AGENT_PLAN.md`](docs/VOICE_AGENT_PLAN.md).

> iOS restriction: Apple does not allow custom keyboard extensions to access the microphone, and current iOS versions can reject audio-session activation from a background Shortcut. The keyboard therefore shows Action Button guidance, while the physical Action Button, Siri, or Shortcuts opens WhisperDict and starts recording in the foreground. Third-party keyboards are unavailable in secure fields, phone-pad fields, and apps that disable custom keyboards.

Build source without signing profiles:

```bash
xcodebuild -scheme WhisperDict \
  -project WhisperDict.xcodeproj \
  -derivedDataPath .build/DerivedData \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Run the core behavior tests with:

```bash
swift test
```

To install on a physical iPhone, the project needs an Apple Developer team with App IDs for `com.dmares06.whisperdict`, `com.dmares06.whisperdict.keyboard`, and `com.dmares06.whisperdict.liveactivity`, the shared App Group `group.com.dmares06.whisperdict`, and a connected device. Automatic signing can create the development profiles.
