#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PROJECT="whitenoise-mac.xcodeproj"
APP_TARGET="whitenoise-mac"
INFO_PLIST="Config/Info.plist"
ENTITLEMENTS="whitenoise-mac/whitenoise-mac.entitlements"
MARMOT_XCFRAMEWORK_INFO="Vendored/MarmotKit/MarmotKit.xcframework/Info.plist"

fail() {
  echo "error: $*" >&2
  exit 1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

assert_plist_equals() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(plist_value "$file" "$key")"
  [[ "$actual" == "$expected" ]] || fail "$file:$key expected '$expected' but found '$actual'"
}

assert_plist_nonempty() {
  local file="$1"
  local key="$2"
  local actual
  actual="$(plist_value "$file" "$key")"
  [[ -n "$actual" ]] || fail "$file:$key must be present and non-empty"
}

assert_entitlement_true() {
  local key="$1"
  local actual
  actual="$(plist_value "$ENTITLEMENTS" "$key")"
  [[ "$actual" == "true" ]] || fail "$ENTITLEMENTS:$key expected true but found '$actual'"
}

build_settings_file="$(mktemp)"
trap 'rm -f "$build_settings_file"' EXIT

xcodebuild \
  -project "$PROJECT" \
  -target "$APP_TARGET" \
  -configuration Release \
  -showBuildSettings > "$build_settings_file"

build_setting() {
  local key="$1"
  awk -v key="$key" '
    $1 == key && $2 == "=" {
      $1 = ""
      $2 = ""
      sub(/^[[:space:]]+/, "")
      value = $0
    }
    END { print value }
  ' "$build_settings_file"
}

assert_build_setting_equals() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(build_setting "$key")"
  [[ "$actual" == "$expected" ]] || fail "Release build setting $key expected '$expected' but found '$actual'"
}

plutil -lint "$INFO_PLIST" >/dev/null
plutil -lint "$ENTITLEMENTS" >/dev/null
plutil -lint "$MARMOT_XCFRAMEWORK_INFO" >/dev/null

assert_plist_equals "$INFO_PLIST" "CFBundleDisplayName" "White Noise"
assert_plist_equals "$INFO_PLIST" "CFBundlePackageType" "APPL"
assert_plist_equals "$INFO_PLIST" "LSApplicationCategoryType" "public.app-category.social-networking"
assert_plist_equals "$INFO_PLIST" "LSMinimumSystemVersion" "\$(MACOSX_DEPLOYMENT_TARGET)"
assert_plist_nonempty "$INFO_PLIST" "NSMicrophoneUsageDescription"
assert_plist_nonempty "$INFO_PLIST" "DarkmatterTelemetryOTLPEndpoint"

assert_entitlement_true "com.apple.security.app-sandbox"
assert_entitlement_true "com.apple.security.network.client"
assert_entitlement_true "com.apple.security.files.user-selected.read-only"
assert_entitlement_true "com.apple.security.device.audio-input"

assert_build_setting_equals "PRODUCT_BUNDLE_IDENTIFIER" "dev.ipf.whitenoise.mac"
assert_build_setting_equals "PRODUCT_NAME" "White Noise"
assert_build_setting_equals "INFOPLIST_FILE" "Config/Info.plist"
assert_build_setting_equals "CODE_SIGN_ENTITLEMENTS" "whitenoise-mac/whitenoise-mac.entitlements"
assert_build_setting_equals "ENABLE_HARDENED_RUNTIME" "YES"
assert_build_setting_equals "ENABLE_APP_SANDBOX" "YES"
assert_build_setting_equals "ENABLE_USER_SELECTED_FILES" "readonly"
assert_build_setting_equals "MACOSX_DEPLOYMENT_TARGET" "15.6"

marmot_platform="$(plist_value "$MARMOT_XCFRAMEWORK_INFO" "AvailableLibraries:0:SupportedPlatform")"
marmot_arch="$(plist_value "$MARMOT_XCFRAMEWORK_INFO" "AvailableLibraries:0:SupportedArchitectures:0")"
[[ "$marmot_platform" == "macos" ]] || fail "MarmotKit platform expected macos but found '$marmot_platform'"
[[ "$marmot_arch" == "arm64" ]] || fail "MarmotKit architecture expected arm64 but found '$marmot_arch'"

echo "macOS project sanity checks passed"
