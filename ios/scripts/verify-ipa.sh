#!/usr/bin/env bash
#
# Check an unsigned .ipa before it is published or handed to AltStore/Sideloadly.
#
#   ./ios/scripts/verify-ipa.sh build/DSHMobile-unsigned.ipa
#   SIGNED=1 ./ios/scripts/verify-ipa.sh build/DSHMobile-signed.ipa   # expect a signature
#
# Exits non-zero on any failed check; issues GitHub Actions annotations when run
# inside Actions.

set -euo pipefail

IPA="${1:-build/DSHMobile-unsigned.ipa}"
SIGNED="${SIGNED:-0}"

FAILED=0
fail() { printf '::error::%s\n' "$*" >&2; FAILED=1; }
ok()   { printf 'ok   %s\n' "$*"; }
warn() { printf 'warn %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }

[[ -f "$IPA" ]] || { printf '::error::No such file: %s\n' "$IPA" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if ! unzip -q "$IPA" -d "$work"; then
  printf '::error::%s is not a readable zip archive.\n' "$IPA" >&2
  exit 1
fi

section "Layout"
if [[ ! -d "$work/Payload" ]]; then
  fail "missing Payload/ directory (not an .ipa)"
  printf 'contents:\n'; ls -A "$work" || true
  exit 1
fi
ok "Payload/ present"

shopt -s nullglob
apps=("$work"/Payload/*.app)
shopt -u nullglob
if [[ ${#apps[@]} -ne 1 ]]; then
  fail "expected exactly one Payload/*.app, found ${#apps[@]}"
  exit 1
fi
app="${apps[0]}"
ok "app bundle: $(basename "$app")"

section "Info.plist"
plutil -lint "$app/Info.plist" >/dev/null 2>&1 && ok "valid plist" || fail "Info.plist does not parse"
extract() { plutil -extract "$1" raw -o - "$app/Info.plist" 2>/dev/null || true; }

for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion CFBundleExecutable; do
  value="$(extract "$key")"
  if [[ -n "$value" ]]; then ok "$key = $value"; else fail "$key is missing or empty"; fi
done

build_number="$(extract CFBundleVersion)"
if [[ -n "$build_number" && "$build_number" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
  ok "CFBundleVersion is numeric (must increase on every re-sign)"
else
  fail "CFBundleVersion '$build_number' is not a dotted numeric value"
fi

exe="$(extract CFBundleExecutable)"
if [[ -n "$exe" && -f "$app/$exe" ]]; then
  ok "executable present"
  archs="$(lipo -archs "$app/$exe" 2>/dev/null || echo unknown)"
  case " $archs " in
    *" arm64 "*) ok "arm64 slice: $archs" ;;
    *) fail "no arm64 slice (found: $archs)" ;;
  esac
else
  fail "executable '$exe' is missing"
fi

section "Signature state"
if [[ "$SIGNED" == "1" ]]; then
  if codesign --verify --deep --strict "$app" 2>/dev/null; then ok "codesign verifies"; else fail "codesign --verify failed"; fi
else
  [[ ! -e "$app/_CodeSignature" ]] && ok "no _CodeSignature (expected for an unsigned build)" || fail "_CodeSignature present: the package is signed"
  [[ ! -e "$app/embedded.mobileprovision" ]] && ok "no embedded.mobileprovision" || fail "embedded.mobileprovision present"
  shopt -s nullglob
  ent=("$app"/*.entitlements)
  shopt -u nullglob
  [[ ${#ent[@]} -eq 0 ]] && ok "no entitlements file shipped" || fail "entitlements file shipped inside the bundle: ${ent[0]##*/}"
fi

section "Keys a free Apple ID cannot use"
forbid() {
  if plutil -extract "$1" raw -o - "$app/Info.plist" >/dev/null 2>&1; then
    fail "$1 must not appear in Info.plist"
  else
    ok "no $1"
  fi
}
forbid UIBackgroundModes
forbid NSAppTransportSecurity.NSAllowsArbitraryLoads
forbid NSAppTransportSecurity.NSAllowsArbitraryLoadsInWebContent

section "Usage descriptions (warnings only)"
for key in NSLocalNetworkUsageDescription NSCameraUsageDescription NSMicrophoneUsageDescription NSPhotoLibraryUsageDescription; do
  value="$(extract "$key")"
  if [[ -n "$value" ]]; then ok "$key set"; else warn "$key not set (only needed when that feature is implemented)"; fi
done

section "Artifact"
printf 'path    %s\nsize    %s bytes\nsha256  %s\n' \
  "$IPA" "$(wc -c < "$IPA" | tr -d ' ')" "$(shasum -a 256 "$IPA" | awk '{print $1}')"

if [[ $FAILED -ne 0 ]]; then
  printf '::error::Verification failed for %s\n' "$IPA" >&2
  exit 1
fi
printf '\nVerification passed.\n'
