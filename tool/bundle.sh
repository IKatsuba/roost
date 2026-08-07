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

# An ad-hoc signature: a local build needs no Developer ID, and without a
# signature at all macOS gives the app no stable identity. The release is signed
# for real, by tool/release.sh.
#
# --options runtime even here, where nothing demands it: the hardened runtime is
# what notarisation requires, and anything it forbids should show up in the
# build you run every day rather than in the one already sent to Apple.
codesign --force --options runtime --sign - "$APP" >/dev/null

# Tell LaunchServices about the bundle that has just appeared. Every build wipes
# the directory and writes it anew, so the old record keeps pointing at an inode
# that no longer exists — and the record is how the system finds the icon by
# bundle id. The notification daemon resolves it exactly that way and, on a dead
# record, draws its generic placeholder instead of the app's icon. The Dock does
# not give the trap away: it holds the icon of the running process.
"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" \
  -f "$APP" 2>/dev/null || true

echo "$ROOT/$APP"
