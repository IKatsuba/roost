#!/bin/sh
# Prepares Roost.app for somebody else's Mac: a universal binary, a Developer ID
# signature, notarisation, and a .zip next to it.
#
# It differs from tool/bundle.sh in three ways: the binary is built for both
# architectures, the signature is a real one rather than ad-hoc, and the bundle
# is packed — your own machine does with one architecture and no Gatekeeper,
# somebody else's may turn out to be Intel and will certainly ask Apple.
#
#   tool/release.sh            universal: arm64 + x86_64
#   tool/release.sh arm64      Apple Silicon only, twice as fast
#
#   ROOST_SIGN_IDENTITY=…      which certificate to sign with (default: the only
#                              Developer ID Application in the keychain)
#   ROOST_NOTARY_PROFILE=…     notarytool keychain profile (default: roost-notary)
#   ROOST_NOTARY_KEY=…         path to the App Store Connect .p8; with it, the
#   ROOST_NOTARY_KEY_ID=…      three replace the profile — CI has the credentials
#   ROOST_NOTARY_ISSUER=…      as secrets and no keychain worth storing them in
#   ROOST_SKIP_NOTARIZE=1      sign but do not notarise — for trying the build
#                              out, since a submission takes minutes
#
# SPM's --arch flag will not do here: it switches the build over to Xcode's
# build system, which goes off to compile SwiftTerm's shader and demands a Metal
# Toolchain. So the slices are built separately through --triple and glued with
# lipo.

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# A stored profile is the convenient half of the deal: it lives in the keychain,
# so a release from this machine needs nothing on the command line. A runner has
# no such keychain — it gets the same credentials as secrets and passes them
# through, which is what the three ROOST_NOTARY_KEY* variables are for.
if [ -n "${ROOST_NOTARY_KEY:-}" ]; then
  NOTARY_AUTH="--key $ROOST_NOTARY_KEY --key-id $ROOST_NOTARY_KEY_ID --issuer $ROOST_NOTARY_ISSUER"
else
  NOTARY_AUTH="--keychain-profile ${ROOST_NOTARY_PROFILE:-roost-notary}"
fi

# The identity is looked up rather than written down: the certificate expires
# every few years and its hash changes with it, while there is only ever one
# Developer ID Application in this keychain. A machine without it has no
# business making a release — an ad-hoc fallback would produce a .zip that looks
# like every other one and is refused as damaged on arrival.
IDENTITY="${ROOST_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep 'Developer ID Application' | head -1 \
  | sed 's/.*"\(.*\)"/\1/')}"

if [ -z "$IDENTITY" ]; then
  echo "No Developer ID Application certificate in the keychain." >&2
  echo "Xcode: Settings -> Accounts -> Manage Certificates -> + Developer ID Application." >&2
  exit 1
fi

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
fi

# Signed here rather than in bundle.sh, and after lipo: replacing the binary
# strips whatever signature was on it, so the ad-hoc one from the build is
# overwritten either way.
#
# --options runtime is what notarisation demands — without the hardened runtime
# Apple rejects the submission outright. --timestamp is what outlives the
# certificate: a signature without one stops verifying the day the certificate
# expires, and every copy already downloaded stops launching with it.
#
# No --deep and no nested signatures: the bundle holds one binary and two
# resource bundles with a font and a shader source in them, nothing that carries
# code of its own.
echo "Signing as $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' tool/Info.plist)"
ZIP="build/Roost-$VERSION.zip"

if [ "${ROOST_SKIP_NOTARIZE:-0}" != "1" ]; then
  # Apple is sent a throwaway archive, not the release one: the ticket comes
  # back separately and is stapled into the .app, so the archive built before
  # the submission does not have it inside. The one people download is packed
  # further down, after the staple.
  #
  # ditto rather than zip or an archive from Finder: it keeps permissions and
  # does not break the signature.
  rm -f build/notarize.zip
  ditto -c -k --keepParent "$APP" build/notarize.zip

  # --timeout, because the wait is otherwise unbounded: a submission that hangs
  # on Apple's side would hold a runner until the job's own limit killed it,
  # with nothing in the log to say why.
  # shellcheck disable=SC2086
  xcrun notarytool submit build/notarize.zip $NOTARY_AUTH --wait --timeout 45m
  rm -f build/notarize.zip

  # Stapling is what makes the app launch on a machine that is offline or behind
  # a firewall: without the ticket in the bundle, Gatekeeper goes asking Apple
  # on every first launch, and a rejection there looks exactly like a broken
  # download.
  xcrun stapler staple "$APP"
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
lipo -info "$APP/Contents/MacOS/Roost"

# The same check the other machine will make, and the only one that proves the
# whole chain: "Notarized Developer ID" in the output means signature, ticket
# and staple are all in place.
spctl --assess -t exec -vv "$APP" || true

echo
echo "$ROOT/$ZIP"
shasum -a 256 "$ZIP"
echo
echo "It needs claude installed there: the pane takes it from PATH."
