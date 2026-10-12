#!/bin/zsh
#
# Builds, signs, notarizes and packages an Icey release (maintainers only).
#
# Usage: Scripts/package-release.sh <tag>        e.g. v0.11.13-dev.2-icey.1
#
# Needs: the "Developer ID Application" certificate in the login keychain, the
# notarytool keychain profile "icey-notary", and the Sparkle EdDSA key under
# the account "icey". Output goes to build/release/<tag>/: the DMG, the zip,
# appcast.xml and SHA256SUMS.txt, ready to attach to the GitHub release.
#
set -euo pipefail

TAG="${1:?usage: package-release.sh <tag>}"
NAME="Icey-${TAG#v}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="$ROOT/build/release-derived"
OUT="$ROOT/build/release/$TAG"
TEAM="${DEVELOPMENT_TEAM:-2597HBX46V}"
cd "$ROOT"

# Checks that would otherwise only fail after the build and notarization.
fail() { echo "error: $1" >&2; exit 1; }
PBX="Ice.xcodeproj/project.pbxproj"
grep -q "MARKETING_VERSION = \"${TAG#v}\";" "$PBX" || fail "MARKETING_VERSION isn't ${TAG#v}. Run Scripts/bump-version.sh $TAG first."
BUILD="$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*;' "$PBX" | grep -o '[0-9]\{2,\}' | sort -n | tail -1)"
# A 404 means no published release has an appcast yet. Anything else that
# yields no build number must stop the release, or the check would be skipped.
FEED="https://github.com/leonardovida/icey/releases/latest/download/appcast.xml"
mkdir -p "$(dirname "$OUT")"
STATUS="$(curl -sL -o "$OUT.live-appcast.xml" -w '%{http_code}' "$FEED" || echo 000)"
if [ "$STATUS" = 200 ]; then
  LIVE="$(grep -o '<sparkle:version>[0-9]*' "$OUT.live-appcast.xml" | grep -o '[0-9]*$' || true)"
  rm -f "$OUT.live-appcast.xml"
  [ -n "$LIVE" ] || fail "Couldn't read the build number from the published appcast ($FEED)."
  [ "$BUILD" -gt "$LIVE" ] \
    || fail "Build number $BUILD isn't higher than the published $LIVE, so Sparkle wouldn't offer it. Run Scripts/bump-version.sh $TAG."
elif [ "$STATUS" != 404 ]; then
  rm -f "$OUT.live-appcast.xml"
  fail "Couldn't download the published appcast (HTTP $STATUS), so the build number can't be checked. Try again."
fi
rm -f "$OUT.live-appcast.xml"
[ -f "release-notes/$TAG.md" ] || fail "release-notes/$TAG.md is missing. Copy release-notes/TEMPLATE.md and fill it in."
# Untracked files count too: Xcode compiles every file in the synchronized
# Ice/, Shared/ and MenuBarItemService/ folders, committed or not.
[ -z "$(git status --porcelain -- . ':!build')" ] || [ -n "${ALLOW_DIRTY:-}" ] \
  || fail "Uncommitted or untracked files would ship in the release, and the tag wouldn't match it. Commit them first, or set ALLOW_DIRTY=1."

rm -rf "$OUT" "$OUT.dmgroot"; mkdir -p "$OUT" "$OUT.dmgroot"
# publish-release.sh tags this commit, so the tag always matches the binaries.
git rev-parse HEAD > "$OUT.commit"

# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO keeps get-task-allow out, which notarization rejects.
xcodebuild -project Ice.xcodeproj -scheme Ice -configuration Release -destination platform=macOS \
  -derivedDataPath "$DD" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM" OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build > "$OUT.build.log" 2>&1 || { tail -30 "$OUT.build.log"; exit 1; }
APP="$DD/Build/Products/Release/Icey.app"

# Sparkle ships its helpers signed with its own identity and no timestamp, which
# notarization rejects. Re-sign them, inside out, then everything that contains them.
ID="Developer ID Application"
sign() { codesign --force --options runtime --timestamp --preserve-metadata=entitlements,requirements,flags --sign "$ID" "$@"; }
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SP/XPCServices/Installer.xpc"
sign "$SP/XPCServices/Downloader.xpc"
sign "$SP/Autoupdate"
sign "$SP/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP/Contents/XPCServices/MenuBarItemService.xpc"
sign "$APP"
codesign --verify --deep --strict "$APP"

echo "== Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/upload.zip"
xcrun notarytool submit "$OUT/upload.zip" --keychain-profile icey-notary --wait | tee "$OUT/notary-app.log"
grep -q "status: Accepted" "$OUT/notary-app.log"
xcrun stapler staple "$APP"
rm "$OUT/upload.zip"
ditto -c -k --keepParent "$APP" "$OUT/$NAME.zip"

echo "== Building and notarizing the DMG"
ditto "$APP" "$OUT.dmgroot/Icey.app"
ln -s /Applications "$OUT.dmgroot/Applications"
hdiutil create -volname Icey -srcfolder "$OUT.dmgroot" -ov -format UDZO "$OUT/$NAME.dmg" > /dev/null
rm -rf "$OUT.dmgroot"
codesign --sign "$ID" --timestamp "$OUT/$NAME.dmg"
xcrun notarytool submit "$OUT/$NAME.dmg" --keychain-profile icey-notary --wait | tee "$OUT/notary-dmg.log"
grep -q "status: Accepted" "$OUT/notary-dmg.log"
xcrun stapler staple "$OUT/$NAME.dmg"
spctl -a -vv -t install "$OUT/$NAME.dmg"

echo "== Appcast and checksums"
DERIVED="$DD" "$ROOT/Scripts/make-appcast.sh" "$OUT/$NAME.zip" "$TAG" "$OUT/appcast.xml"
(cd "$OUT" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)
rm -f "$OUT"/notary-*.log
echo "Done: $OUT"
ls -1 "$OUT"
