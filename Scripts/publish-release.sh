#!/bin/bash
#
# Publishes an Icey release built by Scripts/package-release.sh (maintainers only).
#
# Usage: Scripts/publish-release.sh <tag> [target]   e.g. v0.12.1
#
# The tag is created on the commit package-release.sh built (build/release/<tag>.commit),
# so it matches the binaries even if main has moved on. Pass a branch or commit
# as the second argument to override that. With DRY_RUN=1, it only runs the checks.
#
# Refuses to publish unless build/release/<tag>/ has the DMG, the zip, the
# checksums and an appcast.xml that points at this release's zip. Installed
# copies read the appcast of the latest release, so a release without one
# breaks their update checks. The release workflow checks this again on GitHub
# and turns a release without a valid appcast back into a draft.
#
set -euo pipefail

TAG="${1:?usage: publish-release.sh <tag> [target]}"
REPO="leonardovida/icey"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/build/release/$TAG"
TARGET="${2:-$(cat "$DIR.commit" 2>/dev/null || true)}"
NAME="Icey-${TAG#v}"
NOTES="$ROOT/release-notes/$TAG.md"

fail() { echo "error: $1" >&2; exit 1; }

[ -d "$DIR" ] || fail "$DIR not found. Run Scripts/package-release.sh $TAG first."
for f in "$NAME.dmg" "$NAME.zip" SHA256SUMS.txt appcast.xml; do
    [ -f "$DIR/$f" ] || fail "$DIR/$f is missing. Run Scripts/package-release.sh $TAG again."
done
[ -f "$NOTES" ] || fail "$NOTES is missing. Write the release notes first."
[ -n "$TARGET" ] || fail "$DIR.commit is missing, so the built commit is unknown. Pass it: publish-release.sh $TAG <commit>."
git -C "$ROOT" fetch -q origin
git -C "$ROOT" merge-base --is-ancestor "$TARGET" origin/main 2>/dev/null \
    || fail "$TARGET isn't on origin/main. Push or merge it first, so the tag points at public code."
! gh release view "$TAG" --repo "$REPO" > /dev/null 2>&1 || fail "Release $TAG already exists."
grep -q "enclosure url=\"https://github.com/$REPO/releases/download/$TAG/$NAME.zip\"" "$DIR/appcast.xml" \
    || fail "appcast.xml doesn't point at $TAG/$NAME.zip. Run Scripts/package-release.sh $TAG again."
grep -q 'sparkle:edSignature="[^"]\{1,\}"' "$DIR/appcast.xml" || fail "appcast.xml has no EdDSA signature."
(cd "$DIR" && shasum -a 256 -c SHA256SUMS.txt > /dev/null) || fail "Checksums don't match the files in $DIR."

if [ -n "${DRY_RUN:-}" ]; then
    echo "Ready to publish $TAG on $TARGET. Run again without DRY_RUN=1 to publish."
    exit 0
fi

# Only the four release assets, never logs or other files in the folder.
gh release create "$TAG" "$DIR/$NAME.dmg" "$DIR/$NAME.zip" "$DIR/SHA256SUMS.txt" "$DIR/appcast.xml" \
    --repo "$REPO" --target "$TARGET" --title "Icey ${TAG#v}" --notes-file "$NOTES" --latest

echo "Published $TAG. Checking the update feed..."
for attempt in 1 2 3 4 5 6; do
    if curl -fsL "https://github.com/$REPO/releases/latest/download/appcast.xml" | grep -q "/download/$TAG/"; then
        echo "The update feed serves $TAG."
        exit 0
    fi
    sleep 10
done
fail "The latest appcast doesn't point at $TAG yet. Check https://github.com/$REPO/releases and the 'Check release appcast' workflow."
