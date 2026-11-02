#!/usr/bin/env bash
# Runs `swift test`; extra args are passed through (e.g. --filter JevLiveTests).
# With Command Line Tools only (no Xcode) SwiftPM does not find CLT's Testing.framework
# or lib_TestingInterop.dylib, so pass those paths ourselves. With Xcode this is plain `swift test`.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="$(xcode-select -p)"
if [[ "$DEV" == */CommandLineTools ]]; then
    LIB="$DEV/Library/Developer"
    exec swift test \
        -Xswiftc -F -Xswiftc "$LIB/Frameworks" \
        -Xlinker -rpath -Xlinker "$LIB/Frameworks" \
        -Xlinker -rpath -Xlinker "$LIB/usr/lib" \
        "$@"
fi
exec swift test "$@"
