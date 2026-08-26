#!/bin/bash
# Build, install, and launch WhisperDict on a connected iPhone.
#
# Usage:
#   ./ios_run.sh                      # auto-detect the connected device
#   ./ios_run.sh --device <UDID>      # target a specific device
#   ./ios_run.sh --release            # build the Release configuration
#   ./ios_run.sh --no-launch          # build + install only
#   ./ios_run.sh --build-only         # build only
#
# Note: devicectl prints "Failed to load provisioning parameter list ...
# No provider was found." on every invocation. It is harmless noise, not a
# signing failure — install and launch still succeed after it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="WhisperDict.xcodeproj"
SCHEME="WhisperDict"
CONFIGURATION="Debug"
DEVICE_ID="${DEVICE_ID:-}"
DO_INSTALL=1
DO_LAUNCH=1

while [ $# -gt 0 ]; do
    case "$1" in
        --device) DEVICE_ID="$2"; shift 2 ;;
        --release) CONFIGURATION="Release"; shift ;;
        --no-launch) DO_LAUNCH=0; shift ;;
        --build-only) DO_LAUNCH=0; DO_INSTALL=0; shift ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# Resolve the target device. devicectl reports the hardware UDID, which is what
# both xcodebuild's destination and devicectl's --device accept.
if [ -z "$DEVICE_ID" ]; then
    DEVICE_JSON="$(mktemp -t whisperdict-devices)"
    trap 'rm -f "$DEVICE_JSON"' EXIT
    xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1 || true

    DEVICE_INFO="$(python3 - "$DEVICE_JSON" << 'PY'
import json, sys

try:
    with open(sys.argv[1]) as handle:
        devices = json.load(handle)["result"]["devices"]
except (OSError, ValueError, KeyError):
    sys.exit(0)

for device in devices:
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    # Only physical iOS devices that are paired and reachable can be targeted.
    if hardware.get("platform") != "iOS":
        continue
    if connection.get("pairingState") != "paired":
        continue
    udid = hardware.get("udid")
    name = device.get("deviceProperties", {}).get("name", "iPhone")
    if udid:
        print(f"{udid}\t{name}")
        break
PY
)"

    if [ -z "$DEVICE_INFO" ]; then
        echo "❌ No paired iOS device found." >&2
        echo "   Plug in your iPhone, unlock it, and trust this Mac." >&2
        echo "   Or pass one explicitly: ./ios_run.sh --device <UDID>" >&2
        exit 1
    fi

    DEVICE_ID="${DEVICE_INFO%%$'\t'*}"
    DEVICE_NAME="${DEVICE_INFO##*$'\t'}"
else
    DEVICE_NAME="$DEVICE_ID"
fi

echo "📱 Target: ${DEVICE_NAME} (${DEVICE_ID})"

# The app authenticates to the Hermes backend with WHISPERDICT_CLIENT_TOKEN,
# expanded into Info.plist at build time. Nothing in the project supplies it,
# so resolve it here: an exported variable wins, otherwise the production env
# pulled from Vercel (`vercel env pull --environment=production`).
if [ -z "${WHISPERDICT_CLIENT_TOKEN:-}" ]; then
    for env_file in realtime-backend/.vercel/.env.production.local realtime-backend/.env.local; do
        if [ -f "$env_file" ]; then
            WHISPERDICT_CLIENT_TOKEN="$(grep -E '^WHISPERDICT_CLIENT_TOKEN=' "$env_file" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
            [ -n "$WHISPERDICT_CLIENT_TOKEN" ] && break
        fi
    done
fi
if [ -z "${WHISPERDICT_CLIENT_TOKEN:-}" ]; then
    echo "⚠️  No WHISPERDICT_CLIENT_TOKEN found; the Realtime agent and Gmail will not work in this build." >&2
    echo "   Run: (cd realtime-backend && vercel env pull --environment=production .vercel/.env.production.local)" >&2
    TOKEN_SETTING=()
else
    TOKEN_SETTING=("WHISPERDICT_CLIENT_TOKEN=${WHISPERDICT_CLIENT_TOKEN}")
fi

echo "🔨 Building ${SCHEME} (${CONFIGURATION})..."

# -allowProvisioningUpdates lets Xcode refresh the free personal-team profile,
# which expires every 7 days.
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=iOS,id=${DEVICE_ID}" \
    -allowProvisioningUpdates \
    "${TOKEN_SETTING[@]}" \
    build

if [ "$DO_INSTALL" -eq 0 ]; then
    echo "✅ Build succeeded."
    exit 0
fi

# Read the product path and bundle id from the build settings rather than
# hardcoding a DerivedData path, which changes whenever the project moves.
# Keep stderr: this step can fail transiently (package-graph resolution races
# against a concurrent build), and swallowing the message hides the cause.
SETTINGS_ERR="$(mktemp -t whisperdict-settings)"
trap 'rm -f "${DEVICE_JSON:-}" "$SETTINGS_ERR"' EXIT

if ! SETTINGS="$(xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=iOS,id=${DEVICE_ID}" \
    -showBuildSettings 2>"$SETTINGS_ERR")"; then
    echo "❌ Could not read build settings (xcodebuild -showBuildSettings failed):" >&2
    tail -20 "$SETTINGS_ERR" >&2
    exit 1
fi

BUILT_PRODUCTS_DIR="$(echo "$SETTINGS" | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')"
FULL_PRODUCT_NAME="$(echo "$SETTINGS" | awk -F' = ' '/ FULL_PRODUCT_NAME = /{print $2; exit}')"
BUNDLE_ID="$(echo "$SETTINGS" | awk -F' = ' '/ PRODUCT_BUNDLE_IDENTIFIER = /{print $2; exit}')"
APP_PATH="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ Built app not found at: $APP_PATH" >&2
    exit 1
fi

echo "📦 Installing ${FULL_PRODUCT_NAME}..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

if [ "$DO_LAUNCH" -eq 0 ]; then
    echo "✅ Installed. Launch it from the Home Screen."
    exit 0
fi

echo "🚀 Launching ${BUNDLE_ID}..."
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"

echo ""
echo "✅ Running on ${DEVICE_NAME}."
echo "   Keyboard extension: Settings → General → Keyboard → Keyboards → Add New Keyboard"
