#!/bin/sh
# Builds "build/ThatPet Ollama Extension.app" (Apple Silicon + Intel), signed ad hoc.
set -e
cd "$(dirname "$0")/.."
APP="build/ThatPet Ollama Extension.app"
TMP=$(mktemp -d)
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" -lsqlite3 \
    -o "$TMP/ThatPetOllamaExtension-$ARCH" Sources/*.swift
done
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/ThatPetOllamaExtension" "$TMP"/ThatPetOllamaExtension-*
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
rm -rf "$TMP"
echo "Built: $(pwd)/$APP ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist"))"
