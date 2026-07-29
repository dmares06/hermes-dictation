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
    pip install -q faster-whisper mlx-whisper sounddevice pynput pyperclip pyobjc numpy
else
    source "\$VENV_DIR/bin/activate"
fi

# Upgrade existing project environments that predate the MLX backend.
if ! python3 -c "import importlib.util; raise SystemExit(importlib.util.find_spec('mlx_whisper') is None)"; then
    pip install -q mlx-whisper
fi

# Use the venv's real (framework) interpreter — required for the menubar icon
# to render. Shows as "python3.x" in Privacy & Security (cosmetic only).
APP_PY="python3"

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
    <key>CFBundleIconFile</key>
    <string>icon.png</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Hermes Dictation needs microphone access for voice dictation.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Hermes Dictation needs accessibility access to type text at your cursor.</string>
</dict>
</plist>
PLIST

# Create a Hermes app icon: teal-to-violet rounded tile with a white
# microphone mark and a warm signal dot. This is generated without external
# image dependencies so every build stays reproducible.
python3 -c "
import struct, zlib

def create_icon_png(path):
    width, height = 256, 256
    pixels = []
    def rounded_box(x, y, w, h, radius, px, py):
        qx = max(x + radius - px, 0, px - (x + w - radius))
        qy = max(y + radius - py, 0, py - (y + h - radius))
        return qx * qx + qy * qy <= radius * radius

    def distance_to_segment(px, py, ax, ay, bx, by):
        dx, dy = bx - ax, by - ay
        length = dx * dx + dy * dy or 1
        t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / length))
        x, y = ax + t * dx, ay + t * dy
        return ((px - x) ** 2 + (py - y) ** 2) ** 0.5

    for y in range(height):
        row = []
        for x in range(width):
            tile = rounded_box(20, 20, 216, 216, 52, x, y)
            if tile:
                t = (x + y) / (width + height)
                r, g, b, a = int(35 + 85 * t), int(110 - 55 * t), int(112 + 75 * t), 255
            else:
                r, g, b, a = 0, 0, 0, 0

            # White microphone capsule.
            capsule = rounded_box(101, 67, 54, 98, 27, x, y)
            ring = ((x - 128) ** 2 + (y - 126) ** 2) ** 0.5
            arc = abs(ring - 58) < 7 and y >= 126
            stem = distance_to_segment(x, y, 128, 188, 128, 209) < 7 or distance_to_segment(x, y, 99, 211, 157, 211) < 7
            if capsule or arc or stem:
                r, g, b, a = 255, 255, 255, 255
            if (x - 177) ** 2 + (y - 69) ** 2 < 14 ** 2:
                r, g, b, a = 244, 177, 132, 255
            row.extend([r, g, b, a])
        pixels.append(bytes(row))

    raw_data = b''
    for row in pixels:
        raw_data += b'\x00' + row  # Filter byte + row data
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
