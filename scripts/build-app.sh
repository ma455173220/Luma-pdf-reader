#!/bin/zsh
# Builds 知白.app into ./build from the Swift package.
# Usage: scripts/build-app.sh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"

swift build -c release --product Luma

app="build/知白.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Luma "$app/Contents/MacOS/Luma"
cp Resources/Info.plist "$app/Contents/Info.plist"
# Made from the artwork by scripts/make-icon.py.
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# The interface's text: English, and its Simplified Chinese translation (ADR 0006, 丁).
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$app/Contents/Resources/"

# An ad-hoc signature is enough to run on the machine that built it.
codesign --force --sign - "$app" >/dev/null 2>&1

echo "built $app"
