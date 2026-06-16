#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/VideoCompressor"
OUT="$SCRIPT_DIR/Videoquetsche.app"
SIGN_ID="Developer ID Application: aketo GmbH (9H7F5NMT97)"

echo "Building Videoquetsche..."

mkdir -p "$SCRIPT_DIR/build"

swiftc \
  -sdk "$(xcrun --show-sdk-path)" \
  -target arm64-apple-macosx13.0 \
  -framework SwiftUI \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  "$SRC/VideoCompressorApp.swift" \
  "$SRC/VideoProcessor.swift" \
  "$SRC/ContentView.swift" \
  -o "$SCRIPT_DIR/build/VideoCompressor"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
mkdir -p "$OUT/Contents/Resources"
cp "$SCRIPT_DIR/build/VideoCompressor" "$OUT/Contents/MacOS/"
cp "$SRC/Info.plist" "$OUT/Contents/"
cp "$SCRIPT_DIR/AppIcon.icns" "$OUT/Contents/Resources/"
cp "$SRC/VideoCompressor.entitlements" "$SCRIPT_DIR/build/"

echo "Signing..."
codesign \
  --force \
  --deep \
  --sign "$SIGN_ID" \
  --entitlements "$SCRIPT_DIR/build/VideoCompressor.entitlements" \
  --options runtime \
  "$OUT"

echo "Verifying..."
codesign --verify --verbose "$OUT"

echo ""
echo "Done: $OUT"
echo "Öffnen mit: open '$OUT'"
