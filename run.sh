#!/bin/bash
# Hermes Dictation — macOS menubar dictation app launcher
# Local Whisper-based push-to-talk. Drop-in Wispr Flow replacement.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Ensure we're in a venv with dependencies
VENV_DIR="${SCRIPT_DIR}/venv"
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
    pip install -q faster-whisper mlx-whisper sounddevice pynput pyperclip pyobjc numpy
else
    source "$VENV_DIR/bin/activate"
fi

# Existing installations may predate the Apple-Silicon backend.
if ! python3 -c "import importlib.util; raise SystemExit(importlib.util.find_spec('mlx_whisper') is None)"; then
    pip install -q mlx-whisper
fi

# Use the venv's real (framework) interpreter — required for the menubar icon
# to actually render. NOTE: this shows as "python3.x" in Privacy & Security;
# a proper py2app bundle is the correct way to get the app's real name there.
APP_PY="python3"

echo "🎙️  Hermes Dictation Launcher"
echo "   Starting menubar app..."
echo "   Hold Fn / Globe → speak → release → text appears"
echo ""

"$APP_PY" "${SCRIPT_DIR}/dictate.py" "$@"
