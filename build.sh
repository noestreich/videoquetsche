#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/VideoCompressor"
OUT="$SCRIPT_DIR/VideoCompressor.app"

echo "Building VideoCompressor..."

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

mkdir -p "$OUT/Contents/MacOS"
mkdir -p "$OUT/Contents/Resources"
cp "$SCRIPT_DIR/build/VideoCompressor" "$OUT/Contents/MacOS/"
cp "$SRC/Info.plist" "$OUT/Contents/"

echo "Done: $OUT"
echo "Öffnen mit: open '$OUT'"
