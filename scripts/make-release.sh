#!/bin/zsh
# Luoto — a fork of Atoll (DynamicIsland)
# Copyright (C) 2026 amidamaru940 and Luoto contributors
# Licensed under the GNU General Public License v3.0 or later; see LICENSE.
#
# Builds the public release: Luoto.app (no Apple Developer account needed),
# packed into Luoto-<version>.dmg with a link to Applications, plus its SHA-256,
# the update zip and its feed. Uses only Xcode and macOS tools.
#
# With the certificate "Luoto Self-Signed" in the Keychain the app is signed with
# it: to macOS it stays the same app across updates, so Accessibility stays on.
# Without it (anyone else's build) the app is signed ad-hoc. The update zip and
# feed need the EdDSA key that fits Info.plist, and are skipped without it.
#
# Usage: scripts/make-release.sh [output folder]   (default: build/release)
#   LUOTO_RELEASE       set for a real release: stops unless the certificate
#                       and the EdDSA key are there
#   LUOTO_DERIVED       where Xcode builds (default: build/DerivedData-release)
#   LUOTO_PACKAGES      an already fetched SourcePackages folder, to build offline
#   LUOTO_VERSION       another version than the VERSION file (a test release)
#   LUOTO_FEED_URL      another update feed in the app (a test release)
#   LUOTO_RELEASE_BASE  where the feed says the zip is (a test release)

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/release}"
DERIVED="${LUOTO_DERIVED:-build/DerivedData-release}"
PACKAGES=()
[[ -n "${LUOTO_PACKAGES:-}" ]] && PACKAGES=(-clonedSourcePackagesDirPath "$LUOTO_PACKAGES" -disableAutomaticPackageResolution)
VERSION="${LUOTO_VERSION:-$(tr -d '[:space:]' < VERSION)}"
# Sparkle compares this number, so every release must have a higher one.
IFS=. read -r MAJOR MINOR PATCH <<< "$VERSION"
BUILD_NUMBER=$(( MAJOR * 10000 + MINOR * 100 + PATCH ))
IDENTITY_NAME="Luoto Self-Signed"
IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
IDENTITY="$(awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }' <<< "$IDENTITIES")"
# A real release needs the real keys: an ad-hoc update would cost every user
# their Accessibility permission.
RELEASE_CERTIFICATE_SHA1="59D98C10BD5B2050E89F991B5E50C6593EC25064"
if [[ -n "${LUOTO_RELEASE:-}" ]]; then
  [[ -n "$IDENTITY" ]] || { echo "LUOTO_RELEASE: the certificate \"$IDENTITY_NAME\" is not in the Keychain" >&2; exit 1; }
  [[ "$IDENTITY" == "$RELEASE_CERTIFICATE_SHA1" ]] || { echo "LUOTO_RELEASE: this is not the release certificate" >&2; exit 1; }
  [[ -z "${LUOTO_VERSION:-}${LUOTO_FEED_URL:-}${LUOTO_RELEASE_BASE:-}" ]] || { echo "LUOTO_RELEASE: test settings are not for a real release" >&2; exit 1; }
fi
APP_NAME="Luoto"
DMG="$OUT/$APP_NAME-$VERSION.dmg"

mkdir -p "$OUT"
# A feed and zip from an earlier run must not pass for this one's.
rm -f "$OUT/appcast.xml" "$OUT/$APP_NAME-$VERSION.zip"
# Source paths end up in the binary's debug info; map them, and strip the
# debug symbols below (their map names every object file in the build
# folder), so the release does not carry the builder's home. The code uses
# #fileID, not #file, for the same reason (tests/test_fork_configuration.py).
# xcodebuild splits these list settings on spaces unless an item is quoted,
# and the checkout may sit in a folder with a space (a space in a folder name).
ROOT_ABS="$(pwd -P)"
SWIFT_MAP="-file-prefix-map \"$ROOT_ABS=.\" -file-prefix-map \"$HOME=~\""
C_MAP="\"-ffile-prefix-map=$ROOT_ABS=.\" \"-ffile-prefix-map=$HOME=~\""

echo "Building $APP_NAME $VERSION ($BUILD_NUMBER), Release, signed ${IDENTITY:+with $IDENTITY_NAME}${IDENTITY:-ad-hoc}…"
# A failed build must not ship the app a previous build left behind.
rm -rf "$DERIVED/Build/Products/Release/$APP_NAME.app"
# The command line wins over Config/Local.xcconfig: Xcode signs ad-hoc whatever
# team this Mac signs its own builds with, and the certificate comes below.
# Packages come only in the versions Package.resolved names.
set +e
xcodebuild build \
  -project DynamicIsland.xcodeproj -scheme DynamicIsland -configuration Release \
  -destination "platform=macOS,arch=arm64" -derivedDataPath "$DERIVED" "${PACKAGES[@]}" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=debugging \
  OTHER_SWIFT_FLAGS="\$(inherited) $SWIFT_MAP" OTHER_CFLAGS="\$(inherited) $C_MAP" \
  | grep -E "error:|\*\* BUILD"
BUILD_STATUS=${pipestatus[1]}
set -e
(( BUILD_STATUS == 0 )) || { echo "Build failed (xcodebuild exit $BUILD_STATUS)" >&2; exit 1; }

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "Build failed: $APP not found" >&2; exit 1; }
# Sparkle ships without its XPC services: a non-sandboxed app does not use
# them, and they are where Sparkle's published vulnerabilities lived (security
# audit, 30.10.2026). Xcode embeds the framework after the build phases, so they
# go here, and everything is signed again, keeping the app's entitlements.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
ENTITLEMENTS_BEFORE="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
FLAGS_BEFORE="$(codesign -dv "$APP" 2>&1 | grep -o 'flags=[^ ]*')"
find "$SPARKLE" -name XPCServices -maxdepth 3 -exec rm -rf {} +
[[ -z "$(find "$SPARKLE" -name XPCServices -maxdepth 3 2>/dev/null)" ]] || { echo "Sparkle XPC services must not ship" >&2; exit 1; }
[[ -z "${LUOTO_FEED_URL:-}" ]] || plutil -replace SUFeedURL -string "$LUOTO_FEED_URL" "$APP/Contents/Info.plist"
if [[ -n "$IDENTITY" ]]; then
  # Inside out, the app last. No Apple timestamp: this certificate has no use
  # for that network call.
  SIGN=(codesign --force --sign "$IDENTITY" --timestamp=none --options runtime --preserve-metadata=identifier,entitlements)
  find "$APP/Contents" -type f -perm +111 -print0 | while IFS= read -r -d '' item; do
    if [[ "$(file -b "$item")" == Mach-O* ]]; then "${SIGN[@]}" "$item"; fi
  done
  find "$APP/Contents" -depth \( -name '*.dylib' -o -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.app' \) -print0 | while IFS= read -r -d '' item; do
    "${SIGN[@]}" "$item"
  done
  "${SIGN[@]}" "$APP"
  EXPECTED_FLAGS="flags=0x10000(runtime)"
  EXPECTED_SIGNATURE="Authority=$IDENTITY_NAME"
else
  codesign --force --sign - --options runtime --preserve-metadata=identifier,entitlements "$SPARKLE"
  codesign --force --sign - --options runtime --preserve-metadata=identifier,entitlements,requirements,flags "$APP"
  EXPECTED_FLAGS="$FLAGS_BEFORE"
  EXPECTED_SIGNATURE="Signature=adhoc"
fi
[[ "$(codesign -d --entitlements :- "$APP" 2>/dev/null)" == "$ENTITLEMENTS_BEFORE" ]] || { echo "Re-signing changed the entitlements" >&2; exit 1; }
[[ "$(codesign -dv "$APP" 2>&1 | grep -o 'flags=[^ ]*')" == "$EXPECTED_FLAGS" ]] || { echo "Re-signing changed the code-signing flags" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
SIGNATURE="$(codesign -dv --verbose=2 "$APP" 2>&1)"
[[ "$SIGNATURE" == *"$EXPECTED_SIGNATURE"* ]] || { echo "Not signed as expected ($EXPECTED_SIGNATURE)" >&2; exit 1; }
# The released app keeps the app's own entitlements: Apple Events for the
# music players and Notes, and no camera (Luoto has none).
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
[[ "$ENTITLEMENTS" == *"com.apple.security.automation.apple-events"* ]] || { echo "Apple Events entitlement missing" >&2; exit 1; }
[[ "$ENTITLEMENTS" != *"com.apple.security.device.camera"* ]] || { echo "The camera entitlement must not ship" >&2; exit 1; }

# Nothing in the app may name the builder's home folder.
if grep -rlaF "$HOME/" "$APP" >/dev/null; then
  echo "The app still contains paths under $HOME:" >&2
  grep -rlaF "$HOME/" "$APP" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
# The licenses travel with the app (GPL-3.0 for Luoto, BSD-3-Clause for
# mediaremote-adapter: see NOTICE; every other third-party licence:
# THIRD-PARTY-LICENSES).
cp LICENSE "$STAGE/LICENSE.txt"
cp NOTICE "$STAGE/NOTICE.txt"
cp THIRD-PARTY-LICENSES.md "$STAGE/THIRD-PARTY-LICENSES.txt"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
# Only the file name in the checksum line: it is published next to the DMG.
(cd "$OUT" && shasum -a 256 "${DMG:t}") | tee "$DMG.sha256"

# The update: the same app in a zip, its EdDSA signature and the feed.
SPARKLE_BIN="${LUOTO_PACKAGES:-$DERIVED/SourcePackages}/artifacts/sparkle/Sparkle/bin"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -n "$IDENTITY" && -n "$PUBLIC_KEY" && "$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" == "$PUBLIC_KEY" ]]; then
  ZIP="$OUT/$APP_NAME-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  ZIP_ATTRIBUTES="$("$SPARKLE_BIN/sign_update" "$ZIP")"
  [[ "$ZIP_ATTRIBUTES" == *"sparkle:edSignature="* ]] || { echo "The update zip was not signed" >&2; exit 1; }
  RELEASE_PAGE="https://github.com/amidamaru940/luoto/releases/tag/v$VERSION"
  RELEASE_BASE="${LUOTO_RELEASE_BASE:-https://github.com/amidamaru940/luoto/releases/download/v$VERSION}"
  cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$APP_NAME</title>
    <item>
      <title>$APP_NAME $VERSION</title>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.6</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>What is new: <a href="$RELEASE_PAGE">$RELEASE_PAGE</a></p>]]></description>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <enclosure url="$RELEASE_BASE/${ZIP:t}" type="application/octet-stream" $ZIP_ATTRIBUTES/>
    </item>
  </channel>
</rss>
XML
  echo "Update: $ZIP and $OUT/appcast.xml"
else
  if [[ -n "${LUOTO_RELEASE:-}" ]]; then
    rm -f "$DMG" "$DMG.sha256"
    echo "LUOTO_RELEASE: the EdDSA key is missing or does not fit Info.plist" >&2
    exit 1
  fi
  echo "No update zip: this Mac does not have the release keys."
fi
echo "Done: $DMG"
