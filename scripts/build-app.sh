#!/bin/bash
# Builds dist/Puffer.app from the Swift package. Needs only the Command Line
# Tools, not full Xcode.
#
# macOS ties the Accessibility grant to the code signature, so every build
# must be signed with the same certificate or the grant is lost. This script
# signs with, in order:
#   1. $SIGN_ID, if set (e.g. "Developer ID Application: Name (TEAMID)").
#      This is the path for builds given to other people: it signs with the
#      hardened runtime and a secure timestamp, as notarisation requires.
#   2. "Puffer Local Signing", if scripts/make-signing-cert.sh has been run.
#      Local development only; never distribute a build signed this way.
#   3. an ad-hoc signature (the grant is then lost on every rebuild).
#      SIGN_ID=- asks for this explicitly.
#
# Other settings, both used by scripts/release.sh:
#   UNIVERSAL=1   build for Apple silicon and Intel in one binary
#   VERSION=1.2.3 version number to stamp into the app
set -euo pipefail
cd "$(dirname "$0")/.."

app="dist/Puffer.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

if [[ "${UNIVERSAL:-}" == "1" ]]; then
  # One build per architecture, joined with lipo. (swift build's own
  # multi-architecture mode needs full Xcode; this does not.)
  # Each slice is copied aside as it is built: some toolchains put both
  # architectures' products at the same path.
  slices="$(mktemp -d)"
  trap 'rm -rf "$slices"' EXIT
  for arch in arm64 x86_64; do
    swift build -c release --product Puffer --triple "$arch-apple-macosx"
    cp "$(swift build -c release --triple "$arch-apple-macosx" --show-bin-path)/Puffer" "$slices/$arch"
  done
  lipo -create -output "$app/Contents/MacOS/Puffer" "$slices/arm64" "$slices/x86_64"
else
  swift build -c release --product Puffer
  cp "$(swift build -c release --show-bin-path)/Puffer" "$app/Contents/MacOS/Puffer"
fi

cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $VERSION" "$app/Contents/Info.plist"
fi
# AppIcon.icns is generated from icon-source.png by scripts/make-icon.swift.
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# The expansion sound: "Interface Sounds" by Kenney (kenney.nl), CC0.
cp Resources/Pop.caf "$app/Contents/Resources/Pop.caf"

identity="${SIGN_ID:-}"
options=()
if [[ "$identity" == "-" ]]; then
  : # ad-hoc, as asked
elif [[ -n "$identity" ]]; then
  options=(--options runtime --timestamp)
elif security find-certificate -c "Puffer Local Signing" >/dev/null 2>&1; then
  identity="Puffer Local Signing"
else
  identity="-"
  echo "warning: ad-hoc signing; run scripts/make-signing-cert.sh to keep the Accessibility grant across builds" >&2
fi
codesign --force --sign "$identity" ${options[@]+"${options[@]}"} --identifier co.yuca.puffer "$app"

echo "Built $app (signed with: $identity)"
