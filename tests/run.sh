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

swiftc -parse-as-library \
    "$root/app/InvisiButton/Sources/ActionDispatcher.swift" \
    "$root/tests/test_bindings.swift" \
    -o "$test_build/binding-tests"
"$test_build/binding-tests"

swiftc -parse-as-library \
    "$root/app/InvisiButton/Sources/DirectionModel.swift" \
    "$root/app/InvisiButton/Sources/Profiles.swift" \
    "$root/tests/test_profile_calibration.swift" \
    -o "$test_build/profile-calibration-tests"
"$test_build/profile-calibration-tests"
