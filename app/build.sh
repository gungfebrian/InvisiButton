#!/bin/sh
# Build InvisiButton.app. No Xcode project — swiftc plus a hand-written bundle.
# Phase 1: unsigned and local. T-021 owns Developer ID signing and notarization.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/app/build/InvisiButton.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/app/InvisiButton/Resources/Info.plist" "$app/Contents/Info.plist"
swiftc -O -parse-as-library \
    -target arm64-apple-macosx15.0 \
    -o "$app/Contents/MacOS/InvisiButton" \
    "$root"/app/InvisiButton/Sources/*.swift
# Ad-hoc signature so the bundle launches locally.
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "built $app"
