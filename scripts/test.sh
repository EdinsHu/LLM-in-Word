#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
options=()
developer_dir="$(xcode-select -p)"
frameworks="$developer_dir/Library/Developer/Frameworks"
if [[ -d "$frameworks/Testing.framework" ]]; then
    # Standalone Command Line Tools distribute Swift Testing outside the platform SDK.
    options+=(--disable-xctest -Xswiftc -F -Xswiftc "$frameworks"
              -Xlinker -F -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$frameworks"
              -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib")
fi
if (( ${#options[@]} )); then
    exec swift test "${options[@]}" "$@"
fi
exec swift test "$@"
