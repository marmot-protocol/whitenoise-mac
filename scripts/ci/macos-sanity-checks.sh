#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PROJECT="whitenoise-mac.xcodeproj"
APP_TARGET="whitenoise-mac"
INFO_PLIST="Config/Info.plist"
ENTITLEMENTS="whitenoise-mac/whitenoise-mac.entitlements"
MARMOT_PACKAGE="Vendored/MarmotKit/Package.swift"
MARMOT_VERSION_FILE="Vendored/MarmotKit/MARMOT_VERSION"

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

assert_plist_equals "$INFO_PLIST" "CFBundleDisplayName" "White Noise"
assert_plist_equals "$INFO_PLIST" "CFBundlePackageType" "APPL"
assert_plist_equals "$INFO_PLIST" "LSApplicationCategoryType" "public.app-category.social-networking"
assert_plist_equals "$INFO_PLIST" "LSMinimumSystemVersion" "\$(MACOSX_DEPLOYMENT_TARGET)"
assert_plist_nonempty "$INFO_PLIST" "NSMicrophoneUsageDescription"
assert_plist_nonempty "$INFO_PLIST" "WhiteNoiseTelemetryOTLPEndpoint"

assert_entitlement_true "com.apple.security.app-sandbox"
assert_entitlement_true "com.apple.security.network.client"
assert_entitlement_true "com.apple.security.files.user-selected.read-write"
# Attachment downloads write into the folder the user picks in a panel — that pick *is* the sandbox
# grant. This entitlement grants no folder by itself; it only lets the app remember the pick across
# launches, and without it every download would reopen the panel.
assert_entitlement_true "com.apple.security.files.bookmarks.app-scope"
assert_entitlement_true "com.apple.security.device.audio-input"

assert_build_setting_equals "PRODUCT_BUNDLE_IDENTIFIER" "dev.ipf.whitenoise.mac"
assert_build_setting_equals "PRODUCT_NAME" "White Noise"
assert_build_setting_equals "INFOPLIST_FILE" "Config/Info.plist"
assert_build_setting_equals "CODE_SIGN_ENTITLEMENTS" "whitenoise-mac/whitenoise-mac.entitlements"
assert_build_setting_equals "ENABLE_HARDENED_RUNTIME" "YES"
assert_build_setting_equals "ENABLE_APP_SANDBOX" "YES"
assert_build_setting_equals "ENABLE_USER_SELECTED_FILES" "readwrite"
assert_build_setting_equals "MACOSX_DEPLOYMENT_TARGET" "15.6"

# MarmotKit is a pinned remote binary target, so there is no XCFramework in the
# repo to inspect. What can drift instead is the pin itself: the three `let`s in
# Package.swift and the provenance stamped into MARMOT_VERSION are written
# together by scripts/sync-bindings.sh, and editing one by hand without the
# other is the failure this guards against.
marmot_release_id="$(sed -nE 's/^let marmotKitReleaseID = "(.*)"$/\1/p' "$MARMOT_PACKAGE")"
marmot_release_tag="$(sed -nE 's/^let marmotKitReleaseTag = "(.*)"$/\1/p' "$MARMOT_PACKAGE")"
marmot_checksum="$(sed -nE 's/^let marmotKitChecksum = "(.*)"$/\1/p' "$MARMOT_PACKAGE")"

[[ -n "$marmot_release_id" ]] || fail "$MARMOT_PACKAGE is missing marmotKitReleaseID"
[[ "$marmot_release_tag" == "marmotkit-"* ]] || fail "$MARMOT_PACKAGE has an unexpected release tag '$marmot_release_tag'"
[[ "$marmot_checksum" =~ ^[0-9a-f]{64}$ ]] || fail "$MARMOT_PACKAGE checksum is not a 64-character hex digest"
grep -q 'url: marmotKitBinaryURL' "$MARMOT_PACKAGE" \
  || fail "$MARMOT_PACKAGE must declare MarmotKitFFI as a remote binaryTarget, not a local path"
grep -q 'MarmotKitFFI-macos-' "$MARMOT_PACKAGE" \
  || fail "$MARMOT_PACKAGE must pin the macOS asset; an unprefixed MarmotKitFFI asset is the iOS build"

stamped_tag="$(sed -nE 's/^mdk-tag: (.*)$/\1/p' "$MARMOT_VERSION_FILE")"
stamped_checksum="$(sed -nE 's/^swiftpm-checksum: (.*)$/\1/p' "$MARMOT_VERSION_FILE")"
stamped_targets="$(sed -nE 's/^macos-targets: (.*)$/\1/p' "$MARMOT_VERSION_FILE")"
stamped_floor="$(sed -nE 's/^macos-deployment-target: (.*)$/\1/p' "$MARMOT_VERSION_FILE")"

[[ "$stamped_tag" == "$marmot_release_tag" ]] \
  || fail "$MARMOT_VERSION_FILE tag '$stamped_tag' does not match $MARMOT_PACKAGE tag '$marmot_release_tag'"
[[ "$stamped_checksum" == "$marmot_checksum" ]] \
  || fail "$MARMOT_VERSION_FILE checksum does not match the checksum pinned in $MARMOT_PACKAGE"

# The published macOS artifact is Apple Silicon only. If that ever changes
# upstream this fires, rather than the app silently staying arm64-only.
[[ "$stamped_targets" == "aarch64-apple-darwin" ]] \
  || fail "MarmotKit macOS targets expected 'aarch64-apple-darwin' but found '$stamped_targets'"

# The app may require a newer macOS than the library was built for, never older.
app_floor="$(build_setting "MACOSX_DEPLOYMENT_TARGET")"
lowest_floor="$(printf '%s\n%s\n' "$app_floor" "$stamped_floor" | sort -t. -k1,1n -k2,2n | head -1)"
[[ "$lowest_floor" == "$stamped_floor" ]] \
  || fail "app deployment target $app_floor is older than the MarmotKit artifact floor $stamped_floor"

echo "macOS project sanity checks passed"
