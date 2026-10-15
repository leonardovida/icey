#!/bin/bash
#
# Sets the version for the next Icey release (maintainers only).
#
# Usage: Scripts/bump-version.sh <tag>        e.g. v0.12.1
#
# Sets the app's MARKETING_VERSION to the tag without the "v", and raises
# CURRENT_PROJECT_VERSION (the build number) by one. Sparkle only offers an
# update when its build number is higher than the installed one.
#
set -euo pipefail

TAG="${1:?usage: bump-version.sh <tag>}"
VERSION="${TAG#v}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PBX="$ROOT/Ice.xcodeproj/project.pbxproj"

# The app's settings are the only ones with a build number above 1; the
# MenuBarItemService target stays at 1 and 1.0.
BUILD="$(grep -o 'CURRENT_PROJECT_VERSION = [0-9]*;' "$PBX" | grep -o '[0-9]\{2,\}' | sort -n | tail -1)"
OLD_VERSION="$(grep -o 'MARKETING_VERSION = "[^"]*";' "$PBX" | head -1 | sed 's/.*"\(.*\)".*/\1/')"
[ -n "$BUILD" ] && [ -n "$OLD_VERSION" ] || { echo "error: couldn't read the current version from $PBX" >&2; exit 1; }
NEXT=$((BUILD + 1))

sed -i '' \
    -e "s/CURRENT_PROJECT_VERSION = $BUILD;/CURRENT_PROJECT_VERSION = $NEXT;/" \
    -e "s/MARKETING_VERSION = \"$OLD_VERSION\";/MARKETING_VERSION = \"$VERSION\";/" \
    "$PBX"

echo "Version $OLD_VERSION ($BUILD) -> $VERSION ($NEXT)"
