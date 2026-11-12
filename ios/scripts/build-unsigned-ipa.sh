#!/usr/bin/env bash
#
# Archive the iOS app and pack it into an UNSIGNED .ipa.
#
# Unsigned is deliberate: with a free Apple ID the signing identity and the
# provisioning profile are bound to one person's devices, so CI publishes the
# unsigned bundle and the user re-signs it locally (Xcode / AltStore /
# Sideloadly). See docs/05-build-and-signing.md.
#
# Usage:
#   ./ios/scripts/build-unsigned-ipa.sh
#   SCHEME=MyApp BUILD_NUMBER=42 MARKETING_VERSION=0.2.0 ./ios/scripts/build-unsigned-ipa.sh
#
# Environment overrides:
#   IOS_DIR=ios                 directory holding the project
#   CONTAINER=<path>            explicit .xcworkspace / .xcodeproj
#   SCHEME=DSHMobile            scheme to archive
#   CONFIGURATION=Release
#   DESTINATION=generic/platform=iOS
#   BUILD_DIR=build
#   DERIVED_DATA=<BUILD_DIR>/DerivedData
#   ARCHIVE_NAME=DSHMobile.xcarchive
#   IPA_NAME=DSHMobile-unsigned.ipa
#   BUILD_NUMBER=<utc yyyymmddHHMM>   becomes CURRENT_PROJECT_VERSION
#   MARKETING_VERSION=<empty>         overrides MARKETING_VERSION only when set
#   COMMIT / REPOSITORY               recorded in release.json when set
#
# Writes into $BUILD_DIR: the .xcarchive, the .ipa, DSHMobile.dSYM.zip (when the
# archive has dSYMs), release.json and xcodebuild.log.

set -euo pipefail

IOS_DIR="${IOS_DIR:-ios}"
SCHEME="${SCHEME:-DSHMobile}"
CONFIGURATION="${CONFIGURATION:-Release}"
DESTINATION="${DESTINATION:-generic/platform=iOS}"
BUILD_DIR="${BUILD_DIR:-build}"
DERIVED_DATA="${DERIVED_DATA:-${BUILD_DIR}/DerivedData}"
ARCHIVE_NAME="${ARCHIVE_NAME:-DSHMobile.xcarchive}"
IPA_NAME="${IPA_NAME:-DSHMobile-unsigned.ipa}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
MARKETING_VERSION="${MARKETING_VERSION:-}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "xcodebuild runs on macOS only."
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found; install Xcode and run 'xcode-select --install'."
[[ -d "$IOS_DIR" ]] || die "iOS directory '$IOS_DIR' does not exist."

mkdir -p "$BUILD_DIR" "$DERIVED_DATA"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd)"
LOG="$BUILD_DIR/xcodebuild.log"

if [[ -n "${CONTAINER:-}" ]]; then
  [[ -e "$CONTAINER" ]] || die "CONTAINER=$CONTAINER does not exist."
  if [[ "$CONTAINER" == *.xcworkspace ]]; then
    container_args=(-workspace "$CONTAINER")
  else
    container_args=(-project "$CONTAINER")
  fi
else
  shopt -s nullglob
  workspaces=("$IOS_DIR"/*.xcworkspace)
  projects=("$IOS_DIR"/*.xcodeproj)
  shopt -u nullglob

  if [[ ${#workspaces[@]} -gt 0 ]]; then
    container_args=(-workspace "${workspaces[0]}")
  elif [[ ${#projects[@]} -gt 0 ]]; then
    container_args=(-project "${projects[0]}")
  elif [[ -f "$IOS_DIR/project.yml" ]]; then
    command -v xcodegen >/dev/null 2>&1 || die "$IOS_DIR/project.yml needs XcodeGen: brew install xcodegen."
    log "Generating the Xcode project from $IOS_DIR/project.yml"
    ( cd "$IOS_DIR" && xcodegen generate --spec project.yml )
    shopt -s nullglob
    generated=("$IOS_DIR"/*.xcodeproj)
    shopt -u nullglob
    [[ ${#generated[@]} -gt 0 ]] || die "XcodeGen produced no .xcodeproj."
    container_args=(-project "${generated[0]}")
  else
    die "No .xcworkspace, .xcodeproj or project.yml found under $IOS_DIR/."
  fi
fi
log "Build container: ${container_args[*]}"

if ! xcodebuild "${container_args[@]}" -list -json 2>/dev/null | grep -F "\"$SCHEME\"" >/dev/null; then
  echo "Available schemes:"
  xcodebuild "${container_args[@]}" -list 2>/dev/null || true
  die "Scheme '$SCHEME' was not found in the project."
fi

xcode_args=(
  "${container_args[@]}"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA"
  -archivePath "$BUILD_DIR/$ARCHIVE_NAME"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=""
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)
if [[ -n "$MARKETING_VERSION" ]]; then
  xcode_args+=("MARKETING_VERSION=$MARKETING_VERSION")
fi

log "Archiving $SCHEME ($CONFIGURATION) with $(xcodebuild -version | head -n 1)"
set +e
xcodebuild "${xcode_args[@]}" archive 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e
if [[ $status -ne 0 ]]; then
  echo "--- last 80 log lines ---"
  tail -n 80 "$LOG" || true
  die "xcodebuild archive failed with exit code $status (full log: $LOG)."
fi

ARCHIVE="$BUILD_DIR/$ARCHIVE_NAME"
[[ -d "$ARCHIVE" ]] || die "Archive was not produced at $ARCHIVE."

app_path=""
if /usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$ARCHIVE/Info.plist" >/dev/null 2>&1; then
  app_path="$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$ARCHIVE/Info.plist")"
fi

if [[ -n "$app_path" && -d "$ARCHIVE/Products/$app_path" ]]; then
  app_dir="$ARCHIVE/Products/$app_path"
else
  shopt -s nullglob
  candidates=("$ARCHIVE"/Products/*/*.app)
  shopt -u nullglob
  [[ ${#candidates[@]} -gt 0 ]] || die "No .app bundle found under $ARCHIVE/Products."
  app_dir="${candidates[0]}"
fi
log "App bundle: ${app_dir#$ARCHIVE/}"

payload="$BUILD_DIR/Payload"
rm -rf "$payload"
mkdir -p "$payload"
cp -R "$app_dir" "$payload/"
rm -f "$BUILD_DIR/$IPA_NAME"
( cd "$BUILD_DIR" && zip -qry "$IPA_NAME" Payload )
log "Wrote $IPA_NAME"

dsym_zip=""
if [[ -d "$ARCHIVE/dSYMs" && -n "$(ls -A "$ARCHIVE/dSYMs" 2>/dev/null)" ]]; then
  dsym_zip="$BUILD_DIR/DSHMobile.dSYM.zip"
  rm -f "$dsym_zip"
  ( cd "$ARCHIVE" && zip -qry "DSHMobile.dSYM.zip" dSYMs )
  mv "$ARCHIVE/DSHMobile.dSYM.zip" "$dsym_zip"
  log "Wrote $(basename "$dsym_zip")"
fi

info="$app_dir/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$info" 2>/dev/null || true; }
bundle_id="$(plist CFBundleIdentifier)"
app_version="$(plist CFBundleShortVersionString)"
app_build="$(plist CFBundleVersion)"
min_ios="$(plist MinimumOSVersion)"
[[ -n "$bundle_id" ]] || die "CFBundleIdentifier is missing from $info."

size_bytes="$(stat -f%z "$BUILD_DIR/$IPA_NAME")"
sha256="$(shasum -a 256 "$BUILD_DIR/$IPA_NAME" | awk '{print $1}')"

cat > "$BUILD_DIR/release.json" <<JSON
{
  "version": "$app_version",
  "build": "$app_build",
  "bundleId": "$bundle_id",
  "minIOS": "$min_ios",
  "scheme": "$SCHEME",
  "configuration": "$CONFIGURATION",
  "signed": false,
  "ipa": "$IPA_NAME",
  "ipaBytes": $size_bytes,
  "sha256": "$sha256",
  "commit": "${COMMIT:-}",
  "repository": "${REPOSITORY:-}",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

cat <<SUMMARY
---------------------------------------------
 unsigned iOS build
---------------------------------------------
 bundle id     $bundle_id
 version       ${app_version:-?} (${app_build:-?})
 min iOS       ${min_ios:-?}
 ipa           $BUILD_DIR/$IPA_NAME
 ipa bytes     $size_bytes
 sha256        $sha256
 release.json  $BUILD_DIR/release.json
 log           $LOG
---------------------------------------------
SUMMARY
