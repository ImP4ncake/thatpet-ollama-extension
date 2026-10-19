#!/bin/sh
# Builds the menu bar icon into "ThatPet Ollama Extension.app" (in this folder).
# Then `python3 autostart.py install` copies it next to the bridge and starts it at every login.
set -e
cd "$(dirname "$0")"
BUILD=$(mktemp -d)
mkdir -p "$BUILD/ThatPet Ollama Extension.app/Contents/MacOS"
swiftc -O -swift-version 5 -o "$BUILD/ThatPet Ollama Extension.app/Contents/MacOS/BridgeMenu" menubar/BridgeMenu.swift
cp menubar/Info.plist "$BUILD/ThatPet Ollama Extension.app/Contents/Info.plist"
codesign --force --sign - "$BUILD/ThatPet Ollama Extension.app"
rm -rf "ThatPet Ollama Extension.app"
mv "$BUILD/ThatPet Ollama Extension.app" .
rmdir "$BUILD"
echo "Built: $(pwd)/ThatPet Ollama Extension.app"
