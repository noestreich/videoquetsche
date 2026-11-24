#!/bin/bash
# Build Videoquetsche.app
#
#   ./build.sh              – build + sign (for local testing)
#   ./build.sh --release    – build + sign + notarize + staple + Videoquetsche.zip
#   ./build.sh --publish    – like --release, then create GitHub release v<version>
#                             (needs `gh`, uses RELEASE_NOTES.md as description)
#
# One-time setup for notarization (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials "videoquetsche-notary" \
#     --apple-id "<apple-id>" --team-id "9H7F5NMT97" --password "<app-specific-password>"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/VideoCompressor"
BUILD="$SCRIPT_DIR/build"
OUT="$SCRIPT_DIR/Videoquetsche.app"
ZIP="$SCRIPT_DIR/Videoquetsche.zip"
SIGN_ID="Developer ID Application: aketo GmbH (9H7F5NMT97)"
NOTARY_PROFILE="${NOTARY_PROFILE:-videoquetsche-notary}"

MODE="${1:-}"
case "$MODE" in
  ""|--release|--publish) ;;
  *) echo "Unbekannte Option: $MODE"; exit 1 ;;
esac

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$SRC/Info.plist")
echo "Building Videoquetsche $VERSION..."

rm -rf "$BUILD"
mkdir -p "$BUILD"

SOURCES=(
  "$SRC/VideoCompressorApp.swift"
  "$SRC/VideoProcessor.swift"
  "$SRC/ContentView.swift"
)

# Universal binary (Apple Silicon + Intel)
for ARCH in arm64 x86_64; do
  echo "  compiling $ARCH..."
  swiftc \
    -O \
    -sdk "$(xcrun --show-sdk-path)" \
    -target "$ARCH-apple-macosx13.0" \
    -framework SwiftUI \
    -framework AppKit \
    -framework UniformTypeIdentifiers \
    "${SOURCES[@]}" \
    -o "$BUILD/VideoCompressor-$ARCH"
done
lipo -create -output "$BUILD/VideoCompressor" "$BUILD/VideoCompressor-arm64" "$BUILD/VideoCompressor-x86_64"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
mkdir -p "$OUT/Contents/Resources"
cp "$BUILD/VideoCompressor" "$OUT/Contents/MacOS/"
cp "$SRC/Info.plist" "$OUT/Contents/"
cp "$SCRIPT_DIR/AppIcon.icns" "$OUT/Contents/Resources/"

echo "Signing..."
codesign \
  --force \
  --deep \
  --timestamp \
  --sign "$SIGN_ID" \
  --entitlements "$SRC/VideoCompressor.entitlements" \
  --options runtime \
  "$OUT"

echo "Verifying..."
codesign --verify --strict --verbose=2 "$OUT"

if [ -z "$MODE" ]; then
  echo ""
  echo "Done: $OUT"
  echo "Öffnen mit: open '$OUT'"
  exit 0
fi

echo "Notarizing (profile: $NOTARY_PROFILE)..."
rm -f "$ZIP"
ditto -c -k --keepParent "$OUT" "$BUILD/notarize.zip"
xcrun notarytool submit "$BUILD/notarize.zip" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "Stapling..."
xcrun stapler staple "$OUT"
xcrun stapler validate "$OUT"
spctl --assess --type execute --verbose "$OUT"

echo "Packaging..."
ditto -c -k --keepParent "$OUT" "$ZIP"

echo ""
echo "Done: $ZIP (notarisiert, Version $VERSION)"

if [ "$MODE" = "--publish" ]; then
  echo "Creating GitHub release v$VERSION..."
  gh release create "v$VERSION" "$ZIP" \
    --title "Videoquetsche $VERSION" \
    --notes-file "$SCRIPT_DIR/RELEASE_NOTES.md"
fi
