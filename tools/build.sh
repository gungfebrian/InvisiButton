#!/bin/sh
# Build the InvisiButton command-line tools. No SwiftPM, no dependencies.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tools/bin"
swiftc -O "$root/tools/capture/main.swift" -o "$root/tools/bin/capture"
echo "built $root/tools/bin/capture"
