#!/bin/sh
# Prepares Roost.app for sending to somebody else's Mac and puts a .zip next to
# it.
#
# It differs from tool/bundle.sh in two ways: the binary is built for both
# architectures, and the bundle is packed — your own machine does with one
# architecture, somebody else's may turn out to be Intel.
#
#   tool/release.sh            universal: arm64 + x86_64
#   tool/release.sh arm64      Apple Silicon only, twice as fast
#
# SPM's --arch flag will not do here: it switches the build over to Xcode's
# build system, which goes off to compile SwiftTerm's shader and demands a Metal
# Toolchain. So the slices are built separately through --triple and glued with
# lipo.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The path is known without asking: besides it, bundle.sh also prints the whole
# build log, and catching that from a substitution would only spoil APP.
tool/bundle.sh release >/dev/null
APP="build/Roost.app"

if [ "${1:-universal}" != "arm64" ]; then
  swift build -c release --triple x86_64-apple-macosx14.0 --product Roost
  INTEL="$(swift build -c release --triple x86_64-apple-macosx14.0 --product Roost --show-bin-path | tail -1)"

  lipo -create "$APP/Contents/MacOS/Roost" "$INTEL/Roost" \
    -output "$APP/Contents/MacOS/Roost.universal"
  mv "$APP/Contents/MacOS/Roost.universal" "$APP/Contents/MacOS/Roost"

  # Replacing the binary strips the signature, so we sign again — and this time
  # the fully assembled bundle.
  codesign --force --sign - "$APP" >/dev/null
fi

codesign --verify --strict "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' tool/Info.plist)"
ZIP="build/Roost-$VERSION.zip"

# ditto rather than zip or an archive from Finder: it keeps permissions and does
# not break the signature.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
lipo -info "$APP/Contents/MacOS/Roost"
echo "$ROOT/$ZIP"
echo
echo "On that machine: unpack it, put it in /Applications and clear quarantine —"
echo "the signature is ad-hoc, without a Developer ID, so Gatekeeper would"
echo "refuse to launch the app otherwise:"
echo
echo "  xattr -dr com.apple.quarantine /Applications/Roost.app"
echo
echo "It also needs claude installed there: the pane takes it from PATH."
