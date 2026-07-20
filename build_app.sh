#!/bin/bash
# Build a macOS .app bundle for Hermes Dictation

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Hermes Dictation"
APP_BUNDLE="$SCRIPT_DIR/dist/${APP_NAME}.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "📦 Building ${APP_NAME}.app..."
rm -rf "$APP_BUNDLE"

# Create bundle structure
mkdir -p "$MACOS" "$RESOURCES"

# Create the launcher executable.
# PROJECT_DIR is baked in at build time (absolute) so the app works even when
# copied to /Applications, where a relative path would resolve incorrectly.
cat > "$MACOS/HermesDictation" << LAUNCHER
#!/bin/bash
PROJECT_DIR="$SCRIPT_DIR"

cd "\$PROJECT_DIR"

# Set up venv if needed
VENV_DIR="\$PROJECT_DIR/venv"
if [ ! -d "\$VENV_DIR" ]; then
    python3 -m venv "\$VENV_DIR"
    source "\$VENV_DIR/bin/activate"
    pip install -q faster-whisper sounddevice pynput pyperclip pyobjc numpy
else
    source "\$VENV_DIR/bin/activate"
fi

# Run under an interpreter named "Hermes Dictation" so macOS Privacy prompts
# and the Accessibility/Microphone lists show the app's name, not "python3.x".
APP_PY="\$VENV_DIR/bin/Hermes Dictation"
if [ ! -f "\$APP_PY" ]; then
    cp "\$(python3 -c 'import os,sys; print(os.path.realpath(sys.executable))')" "\$APP_PY"
fi

# Request microphone access
"\$APP_PY" -c "
import AVFoundation
AVFoundation.AVCaptureDevice.requestAccessForMediaType_completionHandler_(
    AVFoundation.AVMediaTypeAudio, lambda granted: None
)
" 2>/dev/null

exec "\$APP_PY" "\$PROJECT_DIR/dictate.py"
LAUNCHER

chmod +x "$MACOS/HermesDictation"

# Create Info.plist
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>HermesDictation</string>
    <key>CFBundleIdentifier</key>
    <string>com.mares.hermes-dictation</string>
    <key>CFBundleName</key>
    <string>Hermes Dictation</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Hermes Dictation needs microphone access for voice dictation.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Hermes Dictation needs accessibility access to type text at your cursor.</string>
</dict>
</plist>
PLIST

# Create an app icon (simple generated icon)
python3 -c "
import struct, zlib

def create_icon_png(path):
    '''Create a minimal PNG icon - a microphone emoji-style icon.'''
    width, height = 128, 128
    
    # Simple gradient circle with mic symbol
    pixels = []
    cx, cy = width // 2, height // 2
    for y in range(height):
        row = []
        for x in range(width):
            dx, dy = x - cx, y - cy
            dist = (dx*dx + dy*dy) ** 0.5
            
            if dist < 50:
                # Purple gradient circle
                t = dist / 50
                r = int(120 * (1 - t) + 80 * t)
                g = int(80 * (1 - t) + 40 * t)
                b = int(200 * (1 - t) + 160 * t)
                a = 255
            elif dist < 55:
                r, g, b, a = 0, 0, 0, 0  # Anti-alias edge
            else:
                r, g, b, a = 0, 0, 0, 0  # Transparent
            row.extend([r, g, b, a])
        pixels.append(bytes(row))
    
    # Simple PNG writer
    raw_data = b''
    for row in pixels:
        raw_data += b'\x00' + row  # Filter byte + row data
    
    # Compress
    compressed = zlib.compress(raw_data)
    
    def chunk(chunk_type, data):
        c = chunk_type + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)
    
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', compressed)
    png += chunk(b'IEND', b'')
    
    with open(path, 'wb') as f:
        f.write(png)

create_icon_png('$RESOURCES/icon.png')
" 2>/dev/null

# Copy project files
cp "$SCRIPT_DIR/dictate.py" "$RESOURCES/" 2>/dev/null || true

echo "✅ Built: $APP_BUNDLE"
echo ""
echo "To install:"
echo "  cp -r \"$APP_BUNDLE\" /Applications/"
echo "  Then launch from Spotlight or /Applications"
echo ""
echo "Or open directly:"
echo "  open \"$APP_BUNDLE\""