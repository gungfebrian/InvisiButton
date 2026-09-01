#!/bin/sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
python3 -m unittest discover -s "$root/tests" -p 'test_*.py'
