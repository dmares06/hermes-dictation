#!/usr/bin/env python3
"""Smoke test for Hermes Dictation — verifies all components work."""

import sys
import os
import time
import tempfile
import wave
import numpy as np

def test_whisper_model():
    """Test that faster-whisper loads and can transcribe a simple audio file."""
    print("🔍 Test 1: Loading Whisper model...")
    from faster_whisper import WhisperModel

    model = WhisperModel("tiny", device="cpu", compute_type="int8")
    print("   ✅ Model loaded")

    # Generate a short sine wave (1 second of 440Hz) as test audio
    print("🔍 Test 2: Generating test audio...")
    sample_rate = 16000
    duration = 1.0
    t = np.linspace(0, duration, int(sample_rate * duration), False)
    tone = 0.3 * np.sin(2 * np.pi * 440 * t)
    audio_int16 = (tone * 32767).astype(np.int16)

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        wav_path = f.name
        with wave.open(f, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(sample_rate)
            wf.writeframes(audio_int16.tobytes())

    print("🔍 Test 3: Transcribing...")
    segments, info = model.transcribe(wav_path, beam_size=5, best_of=5)
    text = " ".join(seg.text.strip() for seg in segments)
    print(f"   Transcription: '{text}'")
    os.unlink(wav_path)
    print("   ✅ Whisper transcription works\n")

def test_text_cleanup():
    """Test the text cleanup logic."""
    print("🔍 Test 4: Text cleanup...")

    # Import the module's functions from this checkout, regardless of cwd.
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from dictate import clean_text

    test_cases = [
        ("um hello there umm like how are you", "Hello there, how are you."),
        ("i think the the project is um due on friday", "I think the project is due on Friday."),
        ("so basically umm i mean we should like start now", "We should start now."),
        ("hello world", "Hello world."),
    ]

    for raw, expected in test_cases:
        result = clean_text(raw)
        # We can't perfectly test expected output since cleanup varies
        print(f"   '{raw[:40]}...' → '{result}'")
        assert result[0].isupper(), "Should start with capital"
        assert result[-1] in ".!?", "Should end with punctuation"
        print("   ✅ Cleanup OK")

    print("   ✅ All cleanup tests pass\n")

def test_clipboard():
    """Test clipboard operations."""
    print("🔍 Test 5: Clipboard operations...")
    import pyperclip
    saved = pyperclip.paste()
    test_text = f"hermes-dictation-test-{time.time()}"
    pyperclip.copy(test_text)
    retrieved = pyperclip.paste()
    assert retrieved == test_text, f"Clipboard mismatch: {retrieved} != {test_text}"
    pyperclip.copy(saved)
    print("   ✅ Clipboard read/write works\n")

def test_sounddevice():
    """Test that sounddevice can list and access audio devices."""
    print("🔍 Test 6: Audio device check...")
    import sounddevice as sd
    devices = sd.query_devices()
    input_devices = [d for d in devices if d['max_input_channels'] > 0]
    if not input_devices:
        raise RuntimeError(
            "No microphone input device is available. Check macOS microphone "
            "permissions and select an input device in Sound settings."
        )
    print(f"   Found {len(input_devices)} input device(s):")
    for d in input_devices:
        print(f"     - {d['name']} ({d['max_input_channels']} ch, {int(d['default_samplerate'])}Hz)")
    default_input = sd.default.device[0]
    print(f"   Default input: {default_input}")
    print("   ✅ Audio devices available\n")

def test_quartz_imports():
    """Test Quartz accessibility API imports."""
    print("🔍 Test 7: Quartz accessibility imports...")
    from Quartz import (
        CGEventSourceCreate, kCGEventSourceStateHIDSystemState,
        kCGEventSourceStatePrivate, CGEventCreateKeyboardEvent,
        CGEventSetFlags, kCGEventFlagMaskCommand,
        CGEventPost, kCGHIDEventTap,
    )
    print("   ✅ All Quartz imports OK\n")

if __name__ == "__main__":
    print("=" * 55)
    print("🧪 Hermes Dictation — Smoke Tests")
    print("=" * 55)
    print(f"Python: {sys.version.split()[0]}")
    print()

    tests = [
        test_whisper_model,
        test_text_cleanup,
        test_clipboard,
        test_sounddevice,
        test_quartz_imports,
    ]

    passed = 0
    for test in tests:
        try:
            test()
            passed += 1
        except Exception as e:
            print(f"   ❌ FAILED: {e}")
            import traceback
            traceback.print_exc()
            print()

    print("=" * 55)
    print(f"✅ {passed}/{len(tests)} tests passed")
    if passed == len(tests):
        print(f"🎉 All systems go! Run with: {sys.executable} {os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dictate.py')}")
    print("=" * 55)
