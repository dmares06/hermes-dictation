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
    pip install -q faster-whisper sounddevice pynput pyperclip pyobjc numpy
else
    source "$VENV_DIR/bin/activate"
fi

# Use the venv's real (framework) interpreter — required for the menubar icon
# to actually render. NOTE: this shows as "python3.x" in Privacy & Security;
# a proper py2app bundle is the correct way to get the app's real name there.
APP_PY="python3"

echo "🎙️  Hermes Dictation Launcher"
echo "   Starting menubar app..."
echo "   Hold Right Option → speak → release → text appears"
echo ""

# Check for microphone permission
MIC_CHECK=$(python3 -c "
import AVFoundation
import objc
status = AVFoundation.AVCaptureDevice.authorizationStatusForMediaType_(AVFoundation.AVMediaTypeAudio)
print(status)
" 2>/dev/null)

# Request mic permission if needed (under the named interpreter so the prompt
# and the Microphone list entry read "Hermes Dictation").
"$APP_PY" -c "
import AVFoundation
import objc
AVFoundation.AVCaptureDevice.requestAccessForMediaType_completionHandler_(
    AVFoundation.AVMediaTypeAudio, lambda granted: None
)
print('Microphone access requested')
" 2>/dev/null

"$APP_PY" "${SCRIPT_DIR}/dictate.py" "$@"