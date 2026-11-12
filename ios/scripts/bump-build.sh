#!/usr/bin/env bash
#
# Set CFBundleVersion in the app Info.plist.
#
# iOS only installs over an existing app when CFBundleVersion increases, and a
# free Apple ID expires every 7 days, so the build number must move on every
# re-sign. The default is a UTC timestamp: monotonic without bookkeeping.
#
#   ./ios/scripts/bump-build.sh                 # yyyymmddHHMM in UTC
#   ./ios/scripts/bump-build.sh 42              # explicit value
#   PLIST=ios/App/Info.plist ./ios/scripts/bump-build.sh
#
# In CI prefer xcodebuild's CURRENT_PROJECT_VERSION (see build-unsigned-ipa.sh)
# so the checked-in Info.plist is not modified.

set -euo pipefail

PLIST="${PLIST:-ios/App/Info.plist}"
BUILD="${1:-${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}}"

die() { printf '::error::%s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "PlistBuddy ships with macOS only."
[[ -f "$PLIST" ]] || die "Info.plist not found at $PLIST (set PLIST=<path>)."
[[ "$BUILD" =~ ^[0-9]+([.][0-9]+)*$ ]] || die "build number '$BUILD' must be dotted digits, e.g. 202608241530."

old="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || true)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
new="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"

printf 'CFBundleVersion %s -> %s in %s\n' "${old:-<none>}" "$new" "$PLIST"
