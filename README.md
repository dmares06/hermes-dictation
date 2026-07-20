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
pip install faster-whisper sounddevice pynput pyperclip pyobjc numpy

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
near the bottom of the screen. The default `small` model favors dictation
accuracy; the first launch downloads its local model and later launches use
the cached copy.

## Hermes Hub

Open **Hermes Hub** from the menubar menu. It is a local-only dashboard with:

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
| `~/.cache/whisper/` | Whisper model cache ~1.5GB |
