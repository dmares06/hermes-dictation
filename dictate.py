#!/usr/bin/env python3
"""
Hermes Dictation — macOS menubar dictation app.
Local Whisper-based push-to-talk. Zero-cost Wispr Flow replacement.

Architecture:
  - Lives in the macOS menubar (status item)
  - Hold a hotkey → record audio → release → transcribe with Whisper → type at cursor
  - Runs entirely locally using faster-whisper

Usage:
  python3 dictate.py
"""

import os
import sys
import time
import tempfile
import wave
import threading
import re
import signal
import queue
import json
import logging
import subprocess
import webbrowser
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import Optional

import AVFoundation
import sounddevice as sd
import numpy as np
from faster_whisper import WhisperModel
import pyperclip
from pynput import keyboard
import Quartz
import objc
from AppKit import (
    NSApplication, NSStatusBar, NSMenu, NSMenuItem, NSImage,
    NSFont, NSWorkspace, NSVariableStatusItemLength,
    NSRunLoop, NSDate, NSTimer, NSColor, NSPanel, NSView, NSBezierPath,
    NSScreen, NSProgressIndicator, NSTextField,
    NSWindowStyleMaskBorderless, NSBackingStoreBuffered,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorStationary, NSFloatingWindowLevel,
    NSProgressIndicatorStyleSpinning, NSControlSizeSmall,
    NSApplicationActivationPolicyAccessory,
)
from Foundation import NSObject, NSLog, NSMakeRect, NSMakePoint
from hermes_store import LocalStore
from hermes_hub import HubServer

# ── Configuration ─────────────────────────────────────────────────────────────
CONFIG_DIR = Path.home() / ".config" / "hermes-dictation"
CONFIG_DIR.mkdir(parents=True, exist_ok=True)
CONFIG_FILE = CONFIG_DIR / "config.json"

DEFAULT_CONFIG = {
    "model_size": "small",       # tiny, base, small, medium, large-v3
    "hotkey": "fn",              # Fn / Globe key
    "language": "en",            # English decoding improves accuracy and speed
    "compute_type": "int8",      # int8, float16, float32
    "device": "auto",            # auto, cpu, cuda
    "sample_rate": 16000,
    "channels": 1,
    "silence_threshold": 0.5,
    "min_silence_ms": 500,
    "auto_punctuate": True,
    "remove_fillers": True,
    "speed_mode": "quality",     # quality or fast
    "show_window": False,        # Show a window on record (future)
    "launch_at_login": False,
}

SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = "float32"
BLOCKSIZE = 1024
TEMP_DIR = Path(tempfile.gettempdir()) / "hermes-dictation"
TEMP_DIR.mkdir(exist_ok=True)

HARD_FILLER_PATTERN = re.compile(
    r"\b(?:um+|uh+|ah+|er+|hmm+|mm+)\b[\s,;:]*", re.IGNORECASE
)
DISCOURSE_FILLER_PATTERN = re.compile(
    r"(?:^|(?<=[.!?,;:]))\s*"
    r"(?:like|so|well|basically|actually|literally|honestly|"
    r"you know|i mean|sort of|kind of)\b\s*[,;:]?\s*",
    re.IGNORECASE,
)


def clean_text(text: str, config: Optional[dict] = None) -> str:
    """Clean up transcribed text using the configured dictation options."""
    if not text:
        return ""

    config = config or DEFAULT_CONFIG
    text = text.strip()

    if config.get("remove_fillers", True):
        # Always remove unmistakable hesitation sounds. Remove softer
        # discourse fillers only at a sentence/discourse boundary so words
        # such as "like" in "I like this" remain intact.
        text = HARD_FILLER_PATTERN.sub("", text)
        text = DISCOURSE_FILLER_PATTERN.sub("", text)

    text = re.sub(r'\b(\w+)\s+\1\b', r'\1', text, flags=re.IGNORECASE)
    text = re.sub(r'\s+', ' ', text).strip()
    text = re.sub(r'\s+([,.!?])', r'\1', text)
    text = text.strip(",;: ")

    if text:
        text = text[0].upper() + text[1:]

    if config.get("auto_punctuate", True) and text and text[-1] not in ".!?":
        text += "."

    return text

# ── Logging ───────────────────────────────────────────────────────────────────
_LOG_FILE = Path.home() / ".config" / "hermes-dictation" / "hermes.log"
_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(_LOG_FILE, mode="a"),
    ],
)
log = logging.getLogger("dictate")

# ── Config ────────────────────────────────────────────────────────────────────

def load_config():
    if CONFIG_FILE.exists():
        try:
            data = json.loads(CONFIG_FILE.read_text())
            merged = DEFAULT_CONFIG.copy()
            merged.update(data)
            return merged
        except Exception as e:
            log.warning(f"Config load failed: {e}")
    return DEFAULT_CONFIG.copy()

def save_config(config):
    CONFIG_FILE.write_text(json.dumps(config, indent=2))
    log.info("Config saved")

# ── Hotkey Mapping ────────────────────────────────────────────────────────────
HOTKEY_MAP = {
    "alt_r": keyboard.Key.alt_r,
    "alt_l": keyboard.Key.alt_l,
    "ctrl_r": keyboard.Key.ctrl_r,
    "ctrl_l": keyboard.Key.ctrl_l,
    "shift_r": keyboard.Key.shift_r,
    "shift_l": keyboard.Key.shift_l,
    "cmd_r": keyboard.Key.cmd_r,
    "cmd_l": keyboard.Key.cmd_l,
    "caps_lock": keyboard.Key.caps_lock,
    "f5": keyboard.Key.f5,
    "f6": keyboard.Key.f6,
    "f7": keyboard.Key.f7,
    "f8": keyboard.Key.f8,
    "f9": keyboard.Key.f9,
    "f10": keyboard.Key.f10,
    "f11": keyboard.Key.f11,
    "f12": keyboard.Key.f12,
}

# The Fn/Globe key is a modifier event on macOS, not the media-key event that
# the old "media_previous" workaround represented. Its virtual key code is
# 0x3F and it sets the secondary-Fn flag on flags-changed events.
FN_KEY = keyboard.KeyCode.from_vk(0x3F)
HOTKEY_MAP["fn"] = FN_KEY
try:
    keyboard.Listener._MODIFIER_FLAGS[FN_KEY] = Quartz.kCGEventFlagMaskSecondaryFn
except AttributeError:
    log.warning("Fn/Globe hotkey is unavailable in this pynput backend")

# ── Dictation Engine ──────────────────────────────────────────────────────────

class DictationEngine:
    """Core dictation engine: manages audio recording, transcription, and typing."""

    def __init__(self, config: dict):
        self.config = config
        self.model: Optional[WhisperModel] = None
        self.is_recording = False
        self.audio_buffer = []
        self.audio_stream: Optional[sd.InputStream] = None
        self._lock = threading.Lock()
        self._hotkey_obj = self._resolve_hotkey()
        self.store: Optional[LocalStore] = None

    def _resolve_hotkey(self):
        key_name = self.config.get("hotkey", "alt_r")
        return HOTKEY_MAP.get(key_name, keyboard.Key.alt_r)

    def _audio_callback(self, indata, frames, time_info, status):
        if status:
            log.warning(f"Audio status: {status}")
        if self.is_recording:
            self.audio_buffer.append(indata.copy())

    def start_stream(self):
        """Start the audio input stream."""
        if self.audio_stream is not None:
            return True
        try:
            self.audio_stream = sd.InputStream(
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                dtype=DTYPE,
                blocksize=BLOCKSIZE,
                callback=self._audio_callback,
            )
            self.audio_stream.start()
            log.info("Audio stream started")
            return True
        except Exception as e:
            log.error(f"Failed to start audio stream: {e}")
            log.warning("Try: brew install portaudio, or check System Settings > Privacy > Microphone")
            return False

    def stop_stream(self):
        if self.audio_stream:
            self.audio_stream.stop()
            self.audio_stream.close()
            self.audio_stream = None
            log.info("Audio stream stopped")

    def load_model(self):
        """Load the Whisper model (once)."""
        if self.model is not None:
            return self.model

        model_size = self.config.get("model_size", "small")
        compute_type = self.config.get("compute_type", "int8")
        device = self.config.get("device", "auto")

        log.info(f"Loading Whisper {model_size}...")
        start = time.time()

        if device == "auto":
            device = "cpu"  # faster-whisper CTranslate2 CPU is fast on Apple Silicon

        self.model = WhisperModel(
            model_size,
            device=device,
            compute_type=compute_type,
            download_root=str(Path.home() / ".cache" / "whisper"),
            cpu_threads=4,
            num_workers=2,
        )
        elapsed = time.time() - start
        log.info(f"Model loaded in {elapsed:.1f}s")
        return self.model

    def start_recording(self):
        """Begin audio capture."""
        with self._lock:
            if self.is_recording:
                return
            self.audio_buffer = []
            self.is_recording = True
        log.info("🎤 Recording...")

    def stop_recording(self) -> Optional[str]:
        """End capture and return path to WAV file."""
        with self._lock:
            if not self.is_recording:
                return None
            self.is_recording = False

        buffer = self.audio_buffer
        self.audio_buffer = []

        if not buffer:
            log.warning("No audio captured")
            return None

        audio = np.concatenate(buffer, axis=0)
        buffer.clear()

        duration = len(audio) / SAMPLE_RATE
        log.info(f"⏹️  {duration:.1f}s captured")

        # Trim silence at start/end
        audio = self._trim_silence(audio)

        if len(audio) < SAMPLE_RATE * 0.1:  # Less than 100ms
            log.info("Audio too short, skipping")
            return None

        # Save to WAV
        timestamp = int(time.time() * 1000)
        wav_path = TEMP_DIR / f"dictation_{timestamp}.wav"

        if audio.dtype != np.float32:
            audio = audio.astype(np.float32)
        audio = np.clip(audio, -1.0, 1.0)

        with wave.open(str(wav_path), "wb") as wf:
            wf.setnchannels(CHANNELS)
            wf.setsampwidth(2)
            wf.setframerate(SAMPLE_RATE)
            audio_int16 = (audio * 32767).astype(np.int16)
            wf.writeframes(audio_int16.tobytes())

        return str(wav_path)

    def _trim_silence(self, audio: np.ndarray, threshold: float = 0.01) -> np.ndarray:
        """Trim silence from beginning and end of audio."""
        abs_audio = np.abs(audio)
        # Find first and last samples above threshold
        above_threshold = np.where(abs_audio > threshold)[0]
        if len(above_threshold) == 0:
            return audio
        start = max(0, above_threshold[0] - SAMPLE_RATE // 20)  # 50ms padding
        end = min(len(audio), above_threshold[-1] + SAMPLE_RATE // 20)
        return audio[start:end]

    def transcribe(self, audio_path: str) -> str:
        """Transcribe audio file to text."""
        model = self.load_model()
        log.info("Transcribing...")
        start = time.time()

        fast_mode = self.config.get("speed_mode", "quality") == "fast"
        segments, info = model.transcribe(
            audio_path,
            beam_size=1 if fast_mode else 5,
            best_of=1 if fast_mode else 5,
            temperature=0.0,
            language=self.config.get("language") or None,
            initial_prompt="Natural English dictation with ordinary punctuation.",
            condition_on_previous_text=False,
            vad_filter=True,
            vad_parameters=dict(
                min_silence_duration_ms=self.config.get("min_silence_ms", 500),
                threshold=self.config.get("silence_threshold", 0.5),
            ),
        )

        text_parts = []
        for segment in segments:
            text_parts.append(segment.text.strip())

        text = " ".join(text_parts)
        elapsed = time.time() - start
        log.info(f"Transcribed {len(text)} chars in {elapsed:.2f}s")
        return text

    def clean_text(self, text: str) -> str:
        """Clean up transcribed text."""
        return clean_text(text, self.config)

    def type_text(self, text: str):
        """Type text at cursor position using Cmd+V."""
        if not text:
            return

        try:
            saved = pyperclip.paste()
            pyperclip.copy(text)

            source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
            if source is None:
                source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStatePrivate)

            # Cmd+V
            key_down = Quartz.CGEventCreateKeyboardEvent(source, 0x09, True)
            Quartz.CGEventSetFlags(key_down, Quartz.kCGEventFlagMaskCommand)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, key_down)

            key_up = Quartz.CGEventCreateKeyboardEvent(source, 0x09, False)
            Quartz.CGEventSetFlags(key_up, Quartz.kCGEventFlagMaskCommand)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, key_up)

            time.sleep(0.05)
            pyperclip.copy(saved)

            log.info(f"✏️  \"{text[:60]}{'...' if len(text) > 60 else ''}\"")

        except Exception as e:
            log.error(f"Failed to type: {e}")

    def process_audio(self, audio_path: str):
        """Full pipeline: transcribe → clean → snippet/type → save history."""
        try:
            duration = 0.0
            try:
                with wave.open(audio_path, "rb") as audio_file:
                    duration = audio_file.getnframes() / max(1, audio_file.getframerate())
            except Exception:
                pass
            raw = self.transcribe(audio_path)
            if not raw:
                log.info("No speech detected")
                return

            cleaned = self.clean_text(raw)
            log.info(f"Raw: \"{raw}\"")
            log.info(f"Clean: \"{cleaned}\"")

            if self.store is not None:
                self.store.add_transcript(cleaned, raw, duration)
                snippet = self.store.resolve_snippet(cleaned)
            else:
                snippet = None

            if snippet and snippet.get("action") == "open":
                target = snippet.get("value", "").strip()
                if target.startswith(("https://", "http://")):
                    webbrowser.open(target)
                    log.info("Opened snippet URL for %s", snippet.get("trigger"))
                else:
                    log.warning("Snippet URL ignored because it is not http(s): %s", target)
            elif snippet:
                self.type_text(snippet.get("value", ""))
            else:
                self.type_text(cleaned)

        except Exception as e:
            log.error(f"Processing failed: {e}")
            import traceback
            traceback.print_exc()
        finally:
            try:
                os.unlink(audio_path)
            except Exception:
                pass


# ── macOS Menubar App ────────────────────────────────────────────────────────

class TranscriptionIndicatorView(NSView):
    """Small floating pill shown while local Whisper is transcribing."""

    def drawRect_(self, rect):
        bounds = self.bounds()
        background = NSColor.colorWithCalibratedWhite_alpha_(0.015, 0.98)
        background.setFill()
        NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(
            bounds, bounds.size.height / 2, bounds.size.height / 2
        ).fill()

        # A restrained dotted waveform, echoing the reference indicator.
        dot_color = NSColor.colorWithCalibratedWhite_alpha_(0.52, 0.9)
        dot_color.setFill()
        dot_sizes = [2, 3, 4, 3, 2, 3, 4]
        for index, dot_height in enumerate(dot_sizes):
            x = 22 + index * 7
            y = (bounds.size.height - dot_height) / 2
            NSBezierPath.bezierPathWithOvalInRect_(NSMakeRect(x, y, 4, dot_height)).fill()


class TranscriptionIndicator(NSPanel):
    """Borderless, non-interactive transcription status panel."""

    def init(self):
        frame = NSMakeRect(0, 0, 240, 54)
        self = objc.super(TranscriptionIndicator, self).initWithContentRect_styleMask_backing_defer_(
            frame,
            NSWindowStyleMaskBorderless,
            NSBackingStoreBuffered,
            False,
        )
        if self:
            self.setOpaque_(False)
            self.setBackgroundColor_(NSColor.clearColor())
            self.setHasShadow_(True)
            self.setLevel_(NSFloatingWindowLevel)
            self.setIgnoresMouseEvents_(True)
            self.setHidesOnDeactivate_(False)
            self.setCollectionBehavior_(
                NSWindowCollectionBehaviorCanJoinAllSpaces
                | NSWindowCollectionBehaviorStationary
            )

            content = TranscriptionIndicatorView.alloc().initWithFrame_(frame)
            self.setContentView_(content)

            label = NSTextField.alloc().initWithFrame_(NSMakeRect(70, 16, 110, 22))
            label.setStringValue_("Listening")
            label.setBezeled_(False)
            label.setDrawsBackground_(False)
            label.setEditable_(False)
            label.setSelectable_(False)
            label.setTextColor_(NSColor.colorWithCalibratedWhite_alpha_(0.82, 1.0))
            label.setFont_(NSFont.systemFontOfSize_(12))
            content.addSubview_(label)

            spinner = NSProgressIndicator.alloc().initWithFrame_(NSMakeRect(198, 15, 24, 24))
            spinner.setStyle_(NSProgressIndicatorStyleSpinning)
            spinner.setControlSize_(NSControlSizeSmall)
            spinner.setIndeterminate_(True)
            spinner.setDisplayedWhenStopped_(False)
            content.addSubview_(spinner)
            self.label = label
            self.spinner = spinner
        return self

    def set_state(self, state):
        self.label.setStringValue_("Listening" if state == "listening" else "Transcribing")

    def show(self, state="transcribing"):
        self.set_state(state)
        screen = NSScreen.mainScreen()
        if screen is not None:
            visible = screen.visibleFrame()
            width, height = 240, 54
            x = visible.origin.x + (visible.size.width - width) / 2
            y = visible.origin.y + 64
            self.setFrameOrigin_(NSMakePoint(x, y))
        self.spinner.startAnimation_(None)
        self.orderFrontRegardless()

    def hide(self):
        self.spinner.stopAnimation_(None)
        self.orderOut_(None)

class AppDelegate(NSObject):
    """NSApplication delegate for the menubar app."""

    def init(self):
        self = objc.super(AppDelegate, self).init()
        if self:
            self.engine = None
            self.status_item = None
            self.menu = None
            self.status_icon = None
            self.listening = False
            self.transcription_indicator = None
            self.ready_status_title = "Ready - Hold Fn / Globe"
            self.store = None
            self.hub = None
            self.paused = False
            self.pause_item = None
        return self

    def setEngine_(self, engine):
        self.engine = engine

    def setStore_(self, store):
        self.store = store
        self.engine.store = store

    def setHub_(self, hub):
        self.hub = hub

    def applicationDidFinishLaunching_(self, notification):
        log.info("App finished launching")
        self.setup_menubar()
        if self.hub is not None:
            self.hub.start()
        self.start_engine()

    def setup_menubar(self):
        """Create the macOS menubar status item."""
        self.transcription_indicator = TranscriptionIndicator.alloc().init()
        configured_hotkey = self.engine.config.get("hotkey", "alt_r")
        hotkey_label = "Fn / Globe" if configured_hotkey == "fn" else configured_hotkey
        self.ready_status_title = f"Ready - Hold {hotkey_label}"

        bar = NSStatusBar.systemStatusBar()
        self.status_item = bar.statusItemWithLength_(NSVariableStatusItemLength)

        # Crisp native menubar icon (SF Symbol, template-styled to match menubar).
        self.status_item.setHighlightMode_(True)
        self.status_item.setVisible_(True)
        self.showIdleIcon()
        button = self.status_item.button()
        log.info(
            f"Menubar status item created: button={button is not None}, "
            f"image={button.image() is not None if button else 'n/a'}, "
            f"visible={self.status_item.isVisible()}"
        )

        # Build menu
        self.menu = NSMenu.alloc().init()

        # Status indicator
        status_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            self.ready_status_title, None, ""
        )
        self.status_indicator = status_item
        self.menu.addItem_(status_item)

        self.menu.addItem_(NSMenuItem.separatorItem())

        # Model selector
        model_menu = NSMenu.alloc().init()
        for size in ["tiny", "base", "small", "medium", "large-v3"]:
            item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                size, "changeModel:", ""
            )
            item.setRepresentedObject_(size)
            if size == self.engine.config.get("model_size"):
                item.setState_(1)
            model_menu.addItem_(item)

        model_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Model", None, ""
        )
        model_item.setSubmenu_(model_menu)
        self.menu.addItem_(model_item)

        # Hotkey selector
        hotkey_menu = NSMenu.alloc().init()
        for key_name in ["alt_r", "alt_l", "ctrl_r", "f5", "f6", "caps_lock", "fn"]:
            title = "Hold Fn / Globe" if key_name == "fn" else f"Hold {key_name}"
            item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                title, "changeHotkey:", ""
            )
            item.setRepresentedObject_(key_name)
            if key_name == self.engine.config.get("hotkey"):
                item.setState_(1)
            hotkey_menu.addItem_(item)

        hotkey_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Hotkey", None, ""
        )
        hotkey_item.setSubmenu_(hotkey_menu)
        self.menu.addItem_(hotkey_item)

        pause_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Pause Dictation", "togglePause:", ""
        )
        self.pause_item = pause_item
        self.menu.addItem_(pause_item)

        hub_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Open Hermes Hub", "openHub:", ""
        )
        self.menu.addItem_(hub_item)

        self.menu.addItem_(NSMenuItem.separatorItem())

        # Quit
        quit_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Quit", "terminate:", "q"
        )
        self.menu.addItem_(quit_item)

        self.status_item.setMenu_(self.menu)

    # ── Menubar icon ─────────────────────────────────────────────────────────
    def _apply_icon(self, symbol_name, recording):
        """Set the menubar icon to an SF Symbol, falling back to emoji."""
        button = self.status_item.button()
        if button is None:
            return
        img = None
        if hasattr(NSImage, "imageWithSystemSymbolName_accessibilityDescription_"):
            img = NSImage.imageWithSystemSymbolName_accessibilityDescription_(
                symbol_name, "Hermes Dictation"
            )
        if img is None:
            # Older macOS without SF Symbols — fall back to text glyphs.
            button.setImage_(None)
            button.setTitle_("🔴" if recording else "🎙️")
            return
        button.setTitle_("")
        # Template images auto-adapt to light/dark menubars; the recording
        # icon is tinted red instead so it clearly stands out.
        img.setTemplate_(not recording)
        button.setImage_(img)
        button.setContentTintColor_(NSColor.systemRedColor() if recording else None)

    def showIdleIcon(self):
        self._apply_icon("mic", False)

    def showRecordingIcon(self):
        self._apply_icon("mic.fill", True)

    def set_recording_icon(self, recording):
        """Update the icon from any thread (UI work marshaled to main thread)."""
        selector = "showRecordingIcon" if recording else "showIdleIcon"
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            selector, None, False
        )

    def showTranscribing(self):
        if self.transcription_indicator is not None:
            self.transcription_indicator.show("transcribing")
        if self.status_indicator is not None:
            self.status_indicator.setTitle_("Transcribing…")

    def showListening(self):
        if self.transcription_indicator is not None:
            self.transcription_indicator.show("listening")
        if self.status_indicator is not None:
            self.status_indicator.setTitle_("Listening… Release to transcribe")

    def hideTranscribing(self):
        if self.transcription_indicator is not None:
            self.transcription_indicator.hide()
        if self.status_indicator is not None:
            self.status_indicator.setTitle_(self.ready_status_title)

    def set_transcribing(self, transcribing):
        """Show or hide the floating indicator from any worker thread."""
        selector = "showTranscribing" if transcribing else "hideTranscribing"
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            selector, None, False
        )

    def set_listening(self, listening):
        """Show the indicator as soon as recording begins."""
        selector = "showListening" if listening else "hideTranscribing"
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            selector, None, False
        )

    def start_engine(self):
        """Start the dictation engine and hotkey listener."""
        engine = self.engine

        # Start audio stream
        engine.start_stream()

        # Load model in background
        threading.Thread(target=engine.load_model, daemon=True).start()

        # Start hotkey listener
        self.hotkey = engine._hotkey_obj
        self.listener_thread = threading.Thread(target=self._run_hotkey_loop, daemon=True)
        self.listener_thread.start()

        log.info("Dictation engine started")

    def _run_hotkey_loop(self):
        """Run the pynput hotkey listener loop."""
        engine = self.engine
        pressed = False
        released = None

        def on_press(key):
            nonlocal pressed, released
            if key == self.hotkey and not pressed and not self.paused:
                pressed = True
                released = threading.Event()
                release_event = released

                def cycle():
                    self.set_recording_icon(True)
                    self.set_listening(True)
                    engine.start_recording()
                    release_event.wait()
                    audio_path = engine.stop_recording()
                    self.set_recording_icon(False)
                    if audio_path:
                        self.set_transcribing(True)
                        try:
                            engine.process_audio(audio_path)
                        finally:
                            self.set_transcribing(False)
                    else:
                        self.set_listening(False)

                threading.Thread(target=cycle, daemon=True).start()
                # Keep this one listener alive so pynput does not repeatedly
                # reinitialize macOS's keyboard input-source state.

        def on_release(key):
            nonlocal pressed, released
            if key == self.hotkey and pressed:
                pressed = False
                if released is not None:
                    released.set()

        # Keep one listener for the lifetime of the app. Recreating it after
        # every dictation can crash macOS 26 inside TSMGetInputSourceProperty.
        with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
            listener.join()

    def changeModel_(self, sender):
        model_size = sender.representedObject()
        log.info(f"Changing model to {model_size}")
        self.engine.config["model_size"] = model_size
        self.engine.model = None  # Force reload
        threading.Thread(target=self.engine.load_model, daemon=True).start()

        # Update menu state
        for item in self.menu.itemArray():
            if item.title() == "Model":
                for sub in item.submenu().itemArray():
                    sub.setState_(1 if sub.representedObject() == model_size else 0)
                break

        save_config(self.engine.config)

    def changeHotkey_(self, sender):
        key_name = sender.representedObject()
        log.info(f"Changing hotkey to {key_name}")
        self.engine.config["hotkey"] = key_name
        self.engine._hotkey_obj = self.engine._resolve_hotkey()
        self.hotkey = self.engine._hotkey_obj

        hotkey_label = "Fn / Globe" if key_name == "fn" else key_name
        self.ready_status_title = f"Ready - Hold {hotkey_label}"
        self.status_indicator.setTitle_(self.ready_status_title)

        for item in self.menu.itemArray():
            if item.title() == "Hotkey":
                for sub in item.submenu().itemArray():
                    sub.setState_(1 if sub.representedObject() == key_name else 0)
                break

        save_config(self.engine.config)

    def togglePause_(self, sender):
        self.paused = not self.paused
        self.refreshSettingsUI()
        log.info("Dictation %s", "paused" if self.paused else "resumed")

    def refreshSettingsUI(self):
        """Apply browser-updated settings on the AppKit main thread."""
        if self.pause_item is not None:
            self.pause_item.setTitle_("Resume Dictation" if self.paused else "Pause Dictation")
        if self.status_indicator is not None:
            self.status_indicator.setTitle_("Paused" if self.paused else self.ready_status_title)

    def openHub_(self, sender):
        if self.hub is not None:
            self.hub.open()

    def get_settings(self):
        settings = dict(self.engine.config)
        settings["paused"] = self.paused
        settings["hub_url"] = self.hub.url if self.hub is not None else None
        return settings

    def update_settings(self, updates):
        allowed = {
            "hotkey", "model_size", "speed_mode", "remove_fillers",
            "auto_punctuate", "paused",
        }
        changed = {key: value for key, value in updates.items() if key in allowed}
        valid_hotkeys = {"fn", "alt_r", "alt_l", "ctrl_r", "f5", "f6", "caps_lock"}
        valid_models = {"tiny", "base", "small", "medium", "large-v3"}
        if "hotkey" in changed and changed["hotkey"] not in valid_hotkeys:
            raise ValueError("Unsupported shortcut")
        if "model_size" in changed and changed["model_size"] not in valid_models:
            raise ValueError("Unsupported model")
        if "speed_mode" in changed and changed["speed_mode"] not in {"fast", "quality"}:
            raise ValueError("Unsupported transcription mode")

        old_model = self.engine.config.get("model_size")
        self.engine.config.update(changed)
        if "hotkey" in changed:
            self.engine._hotkey_obj = self.engine._resolve_hotkey()
            self.hotkey = self.engine._hotkey_obj
            label = "Fn / Globe" if changed["hotkey"] == "fn" else changed["hotkey"]
            self.ready_status_title = f"Ready - Hold {label}"
        if changed.get("model_size") and changed["model_size"] != old_model:
            self.engine.model = None
            threading.Thread(target=self.engine.load_model, daemon=True).start()
        if "paused" in changed:
            self.paused = bool(changed["paused"])
        self.performSelectorOnMainThread_withObject_waitUntilDone_(
            "refreshSettingsUI", None, False
        )
        save_config(self.engine.config)
        return self.get_settings()


def main():
    log.info("═" * 50)
    log.info("🎙️  Hermes Dictation")
    log.info("   Local Whisper dictation for macOS")
    log.info("═" * 50)

    config = load_config()
    log.info(f"Config: model={config['model_size']}, hotkey={config['hotkey']}")

    engine = DictationEngine(config)
    store = LocalStore()

    app = NSApplication.sharedApplication()
    # Force menubar-agent mode (no Dock icon, status item shows) regardless of
    # how the process was launched. Without this, an NSApplication started via
    # an exec'd interpreter may run with no visible UI at all.
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
    delegate = AppDelegate.alloc().init()
    delegate.setEngine_(engine)
    delegate.setStore_(store)
    delegate.setHub_(HubServer(store, delegate.get_settings, delegate.update_settings))
    app.setDelegate_(delegate)
    app.activateIgnoringOtherApps_(True)

    # Request access from the actual app process. A separate short-lived
    # launcher probe could be terminated by macOS before setup completed.
    mic_status = AVFoundation.AVCaptureDevice.authorizationStatusForMediaType_(
        AVFoundation.AVMediaTypeAudio
    )
    if mic_status == AVFoundation.AVAuthorizationStatusNotDetermined:
        log.info("Requesting microphone access")
        AVFoundation.AVCaptureDevice.requestAccessForMediaType_completionHandler_(
            AVFoundation.AVMediaTypeAudio,
            lambda granted: log.info(
                "Microphone access %s", "granted" if granted else "denied"
            ),
        )
    elif mic_status != AVFoundation.AVAuthorizationStatusAuthorized:
        log.warning("Microphone access is not authorized (status=%s)", mic_status)

    log.info("🟢 Running in menubar (activation policy = accessory)")
    app.run()


if __name__ == "__main__":
    main()
