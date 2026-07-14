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
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import Optional

import sounddevice as sd
import numpy as np
from faster_whisper import WhisperModel
import pyperclip
from pynput import keyboard
import Quartz
from AppKit import (
    NSApplication, NSStatusBar, NSMenu, NSMenuItem, NSImage,
    NSFont, NSWorkspace, NSVariableStatusItemLength,
    NSRunLoop, NSDate, NSTimer,
)
from Foundation import NSObject, NSLog

# ── Configuration ─────────────────────────────────────────────────────────────
CONFIG_DIR = Path.home() / ".config" / "hermes-dictation"
CONFIG_DIR.mkdir(parents=True, exist_ok=True)
CONFIG_FILE = CONFIG_DIR / "config.json"

DEFAULT_CONFIG = {
    "model_size": "base",        # tiny, base, small, medium, large-v3
    "hotkey": "alt_r",           # alt_r (Right Option), f5, caps_lock, f6, etc.
    "compute_type": "int8",      # int8, float16, float32
    "device": "auto",            # auto, cpu, cuda
    "sample_rate": 16000,
    "channels": 1,
    "silence_threshold": 0.5,
    "min_silence_ms": 500,
    "auto_punctuate": True,
    "remove_fillers": True,
    "show_window": False,        # Show a window on record (future)
    "launch_at_login": False,
}

SAMPLE_RATE = 16000
CHANNELS = 1
DTYPE = "float32"
BLOCKSIZE = 1024
TEMP_DIR = Path(tempfile.gettempdir()) / "hermes-dictation"
TEMP_DIR.mkdir(exist_ok=True)

FILLER_WORDS = {
    "um", "uh", "uhh", "umm", "ah", "ahh", "er", "hmm", "mm", "mmm",
    "like", "you know", "i mean", "sort of", "kind of", "basically",
    "actually", "literally", "honestly", "so", "well",
}

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
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
    "fn": keyboard.Key.media_previous,  # "fn" maps differently
}

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
            return
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
        except Exception as e:
            log.error(f"Failed to start audio stream: {e}")
            log.warning("Try: brew install portaudio, or check System Settings > Privacy > Microphone")

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

        model_size = self.config.get("model_size", "base")
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

        segments, info = model.transcribe(
            audio_path,
            beam_size=5,
            best_of=5,
            temperature=0.0,
            condition_on_previous_text=True,
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
        if not text:
            return ""

        text = text.strip()

        if self.config.get("remove_fillers", True):
            for filler in FILLER_WORDS:
                pattern = re.compile(r'\b' + re.escape(filler) + r'\b', re.IGNORECASE)
                text = pattern.sub('', text)

        # Remove repeated words
        text = re.sub(r'\b(\w+)\s+\1\b', r'\1', text, flags=re.IGNORECASE)
        # Collapse spaces
        text = re.sub(r'\s+', ' ', text).strip()
        text = text.strip(",;: ")

        # Capitalize
        if text:
            text = text[0].upper() + text[1:]

        if self.config.get("auto_punctuate", True) and text and text[-1] not in ".!?":
            text += "."

        return text

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
        """Full pipeline: transcribe → clean → type."""
        try:
            raw = self.transcribe(audio_path)
            if not raw:
                log.info("No speech detected")
                return

            cleaned = self.clean_text(raw)
            log.info(f"Raw: \"{raw}\"")
            log.info(f"Clean: \"{cleaned}\"")

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

class AppDelegate(NSObject):
    """NSApplication delegate for the menubar app."""

    def init(self):
        self = super().init()
        if self:
            self.engine = None
            self.status_item = None
            self.menu = None
            self.status_icon = None
            self.listening = False
        return self

    def setEngine_(self, engine):
        self.engine = engine

    def applicationDidFinishLaunching_(self, notification):
        log.info("App finished launching")
        self.setup_menubar()
        self.start_engine()

    def setup_menubar(self):
        """Create the macOS menubar status item."""
        bar = NSStatusBar.systemStatusBar()
        self.status_item = bar.statusItemWithLength_(NSVariableStatusItemLength)

        # Create a simple status icon (text-based for now)
        self.status_item.setTitle_("🎙️")
        self.status_item.setHighlightMode_(True)

        # Build menu
        self.menu = NSMenu.alloc().init()

        # Status indicator
        status_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Ready - Hold Right Option", None, ""
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
        for key_name in ["alt_r", "alt_l", "ctrl_r", "f5", "f6", "caps_lock"]:
            item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                f"Hold {key_name}", "changeHotkey:", ""
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

        self.menu.addItem_(NSMenuItem.separatorItem())

        # Quit
        quit_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Quit", "terminate:", "q"
        )
        self.menu.addItem_(quit_item)

        self.status_item.setMenu_(self.menu)

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
        hotkey = self.hotkey

        while True:
            pressed = threading.Event()
            released = threading.Event()
            audio_path_container = [None]

            def on_press(key):
                if key == hotkey and not pressed.is_set():
                    pressed.set()
                    threading.Thread(target=lambda: (
                        engine.start_recording(),
                        released.wait(),
                        (audio_path_container.__setitem__(0, engine.stop_recording()),
                         audio_path_container[0] and engine.process_audio(audio_path_container[0])),
                    ), daemon=True).start()
                    return False

            def on_release(key):
                if key == hotkey and pressed.is_set():
                    released.set()
                    return False

            with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
                listener.join()

            # Small gap between dictations
            time.sleep(0.15)

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

        self.status_indicator.setTitle_(f"Ready - Hold {key_name}")

        for item in self.menu.itemArray():
            if item.title() == "Hotkey":
                for sub in item.submenu().itemArray():
                    sub.setState_(1 if sub.representedObject() == key_name else 0)
                break

        save_config(self.engine.config)


def main():
    log.info("═" * 50)
    log.info("🎙️  Hermes Dictation")
    log.info("   Local Whisper dictation for macOS")
    log.info("═" * 50)

    config = load_config()
    log.info(f"Config: model={config['model_size']}, hotkey={config['hotkey']}")

    engine = DictationEngine(config)

    app = NSApplication.sharedApplication()
    delegate = AppDelegate.alloc().init()
    delegate.setEngine_(engine)
    app.setDelegate_(delegate)
    app.activateIgnoringOtherApps_(True)

    log.info("🟢 Running in menubar")
    app.run()


if __name__ == "__main__":
    main()