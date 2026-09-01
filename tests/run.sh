#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
python3 -m unittest discover -s "$root/tests" -p 'test_*.py'

test_build=$(mktemp -d "${TMPDIR:-/tmp}/invisibutton-tests.XXXXXX")
trap 'rm -rf "$test_build"' EXIT
swiftc -parse-as-library \
    "$root/app/InvisiButton/Sources/Sensor.swift" \
    "$root/tests/test_hardware_support.swift" \
    -o "$test_build/hardware-support-tests"
"$test_build/hardware-support-tests"
