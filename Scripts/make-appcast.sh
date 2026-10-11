#!/bin/bash
#
# Writes the Sparkle appcast for an Icey release.
#
# The app checks https://github.com/leonardovida/icey/releases/latest/download/appcast.xml
# for updates, so every release must carry an `appcast.xml` asset that describes
# itself. The zip it points to must be the notarized, stapled app.
#
# Usage: Scripts/make-appcast.sh <path/to/Icey-<version>.zip> <tag> [output]
#
# Signs the zip with the EdDSA key stored in the login keychain under the
# Sparkle account "icey" (created with `generate_keys --account icey`).
# The public half of that key is SUPublicEDKey in Ice/Resources/Info.plist.
#
set -euo pipefail

ZIP="${1:?usage: make-appcast.sh <zip> <tag> [output]}"
TAG="${2:?usage: make-appcast.sh <zip> <tag> [output]}"
OUT="${3:-appcast.xml}"
REPO="leonardovida/icey"

SIGN_UPDATE="${SIGN_UPDATE:-$(find "${DERIVED:-/tmp/ice-build}" "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*artifacts/sparkle/Sparkle/bin/sign_update' -type f 2>/dev/null | head -1)}"
if [ ! -x "$SIGN_UPDATE" ]; then
    echo "sign_update not found. Build the app once, or set SIGN_UPDATE to Sparkle's sign_update tool." >&2
    exit 1
fi

# Read the version from the app inside the zip, so the appcast can't disagree with it.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"
APP="$(find "$TMP" -maxdepth 1 -name '*.app' | head -1)"
PLIST="$APP/Contents/Info.plist"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$PLIST")"

# Prints: sparkle:edSignature="..." length="..."
SIGNATURE="$("$SIGN_UPDATE" --account icey "$ZIP")"

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Icey</title>
    <link>https://github.com/$REPO/releases</link>
    <description>Icey releases</description>
    <language>en</language>
    <item>
      <title>Icey $SHORT_VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<p>See the <a href="https://github.com/$REPO/releases/tag/$TAG">release notes</a> on GitHub.</p>]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$(basename "$ZIP")" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF

echo "Wrote $OUT for $SHORT_VERSION ($BUILD), tag $TAG"
