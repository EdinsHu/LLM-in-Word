#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build "$@" -c release
bin_dir="$(swift build "$@" -c release --show-bin-path)"
app="dist/WordMath.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Packaging/Info.plist "$app/Contents/Info.plist"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp "$bin_dir/WordMath" "$app/Contents/MacOS/WordMath"
# The packaged application loads its preview directly from Contents/Resources.
ditto Sources/WordMathApp/Resources/Panel "$app/Contents/Resources/Panel"
codesign --force --sign "${WORDMATH_SIGN_IDENTITY:--}" "$app"
codesign --verify "$app"
echo "$PWD/$app"
