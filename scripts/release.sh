#!/bin/sh
# Publishes a new version on GitHub; installed apps pick it up by themselves.
#
#   scripts/release.sh 1.0.1 "Fix for ThatPet 0.5"
#
# It sets the version, builds, runs the simulation (stops on any error), zips and signs the
# app with the key in ~/.config/thatpet-ollama-extension, makes the installer (.dmg), commits,
# tags and creates the GitHub release with the installer, the zip and its .sig (the zip and .sig
# are what installed apps update from).
set -e
cd "$(dirname "$0")/.."
VERSION="$1"
NOTES="${2:-}"
GH=$(command -v gh || echo /opt/homebrew/bin/gh)
[ -n "$VERSION" ] || { echo "usage: scripts/release.sh VERSION [\"release notes\"]"; exit 1; }
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "version must look like 1.2.3"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit or stash your changes first"; exit 1; }
"$GH" auth status >/dev/null 2>&1 || { echo "log in to GitHub first: gh auth login"; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "v$VERSION already exists"; exit 1; }

BUILD=$(( $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD" Resources/Info.plist

scripts/build.sh
APP="build/ThatPet Ollama Extension.app"
echo "Running the simulation…"
python3 -I tests/simulate.py "$PWD/$APP/Contents/MacOS/ThatPetOllamaExtension" > build/simulation.txt 2>&1 || true
if ! grep -q "RESULT: ALL OK" build/simulation.txt; then
  grep -E "^ERR|Traceback" build/simulation.txt || true
  git checkout -- Resources/Info.plist
  echo "Simulation failed: nothing was published (see build/simulation.txt)"
  exit 1
fi

ZIP="build/ThatPet-Ollama-Extension-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sig"
ditto -c -k --keepParent "$APP" "$ZIP"
swift scripts/signing.swift sign "$ZIP"
swift scripts/signing.swift verify "$ZIP"
scripts/make_dmg.sh
DMG="build/ThatPet-Ollama-Extension.dmg"

git add Resources/Info.plist
git commit -q -m "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
"$GH" release create "v$VERSION" "$DMG" "$ZIP" "$ZIP.sig" --title "$VERSION" \
  --notes "${NOTES:-Version $VERSION}

**Install:** download **ThatPet-Ollama-Extension.dmg**, open it and drag the app into Applications. Already installed? It updates itself."
echo "Published $VERSION"
