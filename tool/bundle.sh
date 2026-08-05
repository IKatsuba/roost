#!/bin/sh
# Builds Roost.app out of what SPM gives us.
#
# Xcode is not needed here: it would demand a separate Metal Toolchain for
# SwiftTerm's shader, which `swift build` compiles without one. In exchange the
# bundle has to be assembled by hand — which is exactly a directory, a plist and
# a signature.
#
#   tool/bundle.sh [debug|release]

set -eu

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c "$CONFIGURATION" --product Roost

BIN_PATH="$(swift build -c "$CONFIGURATION" --product Roost --show-bin-path)"
APP="build/Roost.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/Roost" "$APP/Contents/MacOS/Roost"
cp tool/Info.plist "$APP/Contents/Info.plist"

# The icon is kept in the repository ready-made: tool/icon.swift draws it, and
# there is no reason to run that on every build — the palette changes far more
# rarely than the code.
cp tool/Roost.icns "$APP/Contents/Resources/Roost.icns"

# SPM puts packages' resource bundles next to the binary; inside an app their
# place is Contents/Resources, which is where Bundle.module looks for them.
for BUNDLE in "$BIN_PATH"/*.bundle; do
  [ -e "$BUNDLE" ] || continue
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
done

# An ad-hoc signature: a prototype has no Developer ID of its own, and without a
# signature macOS gives the app no stable identity.
codesign --force --sign - "$APP" >/dev/null

echo "$ROOT/$APP"
