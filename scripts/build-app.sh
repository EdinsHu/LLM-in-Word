#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="dist/WordMath.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Packaging/Info.plist "$app/Contents/Info.plist"
cp "$bin_dir/WordMath" "$app/Contents/MacOS/WordMath"
# SwiftPM on macOS may look up a copied bundle relative to Bundle.main.bundleURL.
# The app loads distribution resources explicitly from Contents/Resources.
ditto Sources/WordMathApp/Resources/Panel "$app/Contents/Resources/Panel"
codesign --force --sign "${WORDMATH_SIGN_IDENTITY:--}" "$app"
codesign --verify "$app"
echo "$PWD/$app"
