#!/usr/bin/env bash
# Builds build/Roost.app.
#   SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh   # stable signature (recommended)
#   UNIVERSAL=1 scripts/build-app.sh                            # arm64 + x86_64
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP="build/Roost.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Roost" "$APP/Contents/MacOS/Roost"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signing ("-") works, but macOS ties the Accessibility grant to the signature, so every
# ad-hoc rebuild needs re-granting. Signing with a real identity keeps the grant across builds.
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
