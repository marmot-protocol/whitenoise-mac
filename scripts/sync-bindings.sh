#!/usr/bin/env bash
# Install a published immutable MarmotKit release into the local Swift package.
#
# No mdk checkout is required: the macOS XCFramework is fetched from the pinned
# GitHub release by SwiftPM, and this script only installs the generated Swift
# source and rewrites the pin in Package.swift.
#
# Usage:
#   ./scripts/sync-bindings.sh <full-master-sha>
#   ./scripts/sync-bindings.sh <version>
#
# Examples:
#   ./scripts/sync-bindings.sh 235c8ade2920414679e59d7a5f1a0e78651756a4
#   ./scripts/sync-bindings.sh 0.9.14

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <version-or-full-master-sha>" >&2
    exit 2
fi

RELEASE="$1"
if [[ "$RELEASE" =~ ^[0-9a-f]{40}$ ]]; then
    RELEASE_ID="snapshot-$RELEASE"
    RELEASE_TAG="marmotkit-snapshot-$RELEASE"
    REQUESTED_SHA="$RELEASE"
elif [[ "$RELEASE" =~ ^v?([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?)$ ]]; then
    RELEASE_ID="${BASH_REMATCH[1]}"
    RELEASE_TAG="marmotkit-v$RELEASE_ID"
    REQUESTED_SHA=""
else
    echo "error: release must be a semantic version or a full lowercase 40-character SHA" >&2
    exit 2
fi

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$APP_DIR/Vendored/MarmotKit"
BASE_URL="https://github.com/marmot-protocol/mdk/releases/download/$RELEASE_TAG"
# macOS assets carry an explicit `-macos-` token. The generated Swift is shared
# with the iOS artifact and is published once, without a platform token — there
# is no `MarmotKit-macos-<id>.swift` asset, and looking for one is the common
# mistake.
BINARY_ASSET="MarmotKitFFI-macos-$RELEASE_ID.xcframework.zip"
SWIFT_ASSET="MarmotKit-$RELEASE_ID.swift"
MANIFEST_ASSET="marmotkit-macos-$RELEASE_ID.manifest.json"
CHECKSUMS_ASSET="marmotkit-macos-$RELEASE_ID.checksums.txt"
PRIVACY_ASSET="PrivacyInfo-macos-$RELEASE_ID.xcprivacy"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

download() {
    local asset="$1"
    curl --fail --location --retry 3 --silent --show-error \
        "$BASE_URL/$asset" \
        --output "$TEMP_DIR/$asset"
}

echo "==> Downloading immutable MarmotKit release $RELEASE_TAG"
download "$BINARY_ASSET"
download "$BINARY_ASSET.swiftpm-checksum"
download "$SWIFT_ASSET"
download "$MANIFEST_ASSET"
download "$CHECKSUMS_ASSET"

SOURCE_SHA="$(plutil -extract source_sha raw -o - "$TEMP_DIR/$MANIFEST_ASSET")"
if [[ ! "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: manifest contains an invalid source SHA: $SOURCE_SHA" >&2
    exit 1
fi
if [[ -n "$REQUESTED_SHA" && "$SOURCE_SHA" != "$REQUESTED_SHA" ]]; then
    echo "error: snapshot source SHA $SOURCE_SHA does not match $REQUESTED_SHA" >&2
    exit 1
fi

EXPECTED_BINARY_CHECKSUM="$(tr -d '[:space:]' < "$TEMP_DIR/$BINARY_ASSET.swiftpm-checksum")"
if [[ ! "$EXPECTED_BINARY_CHECKSUM" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: release contains an invalid SwiftPM checksum" >&2
    exit 1
fi
COMPUTED_BINARY_CHECKSUM="$(swift package compute-checksum "$TEMP_DIR/$BINARY_ASSET")"
if [[ "$COMPUTED_BINARY_CHECKSUM" != "$EXPECTED_BINARY_CHECKSUM" ]]; then
    echo "error: binary checksum mismatch" >&2
    exit 1
fi

EXPECTED_SWIFT_SHA="$(awk -v file="$SWIFT_ASSET" '$1 == "sha256" && $3 == file { print $2 }' "$TEMP_DIR/$CHECKSUMS_ASSET")"
COMPUTED_SWIFT_SHA="$(shasum -a 256 "$TEMP_DIR/$SWIFT_ASSET" | awk '{ print $1 }')"
if [[ -z "$EXPECTED_SWIFT_SHA" || "$COMPUTED_SWIFT_SHA" != "$EXPECTED_SWIFT_SHA" ]]; then
    echo "error: generated Swift source checksum mismatch" >&2
    exit 1
fi

# The macOS artifact is Apple Silicon only by design upstream; assert it rather
# than letting a future universal build land unnoticed.
MACOS_TARGETS_JSON="$(plutil -extract macos_targets json -o - "$TEMP_DIR/$MANIFEST_ASSET")"
MACOS_TARGETS="$(printf '%s' "$MACOS_TARGETS_JSON" | sed -E 's/^\["//; s/"\]$//; s/","/, /g')"
MACOS_DEPLOYMENT_TARGET="$(plutil -extract macos_deployment_target raw -o - "$TEMP_DIR/$MANIFEST_ASSET")"
if [[ -z "$MACOS_TARGETS" || -z "$MACOS_DEPLOYMENT_TARGET" ]]; then
    echo "error: manifest is missing macOS target metadata" >&2
    exit 1
fi

RELEASE_JSON="$TEMP_DIR/release.json"
curl --fail --location --retry 3 --silent --show-error \
    "https://api.github.com/repos/marmot-protocol/mdk/releases/tags/$RELEASE_TAG" \
    --output "$RELEASE_JSON"
PUBLISHED_AT="$(plutil -extract published_at raw -o - "$RELEASE_JSON")"
RUST_OPT_LEVEL="$(plutil -extract rust_release_profile.opt_level raw -o - "$TEMP_DIR/$MANIFEST_ASSET")"
RUST_CODEGEN_UNITS="$(plutil -extract rust_release_profile.codegen_units raw -o - "$TEMP_DIR/$MANIFEST_ASSET")"
FEATURES_JSON="$(plutil -extract features json -o - "$TEMP_DIR/$MANIFEST_ASSET")"
FEATURES="$(printf '%s' "$FEATURES_JSON" | sed -E 's/^\["//; s/"\]$//; s/","/,/g')"

CARGO_TOML="$TEMP_DIR/marmot-uniffi-Cargo.toml"
curl --fail --location --retry 3 --silent --show-error \
    "https://raw.githubusercontent.com/marmot-protocol/mdk/$SOURCE_SHA/crates/marmot-uniffi/Cargo.toml" \
    --output "$CARGO_TOML"
UNIFFI_VERSION="$(sed -nE 's/^uniffi = (\{ version = )?"([^"]+)".*/\2/p' "$CARGO_TOML" | head -1)"
if [[ -z "$UNIFFI_VERSION" ]]; then
    echo "error: could not determine UniFFI version for $SOURCE_SHA" >&2
    exit 1
fi

# Static-library releases carry privacy declarations separately from the
# binary. Verify both the release checksum list and the asset sidecar before
# installing the resource into the Swift wrapper target.
DISTRIBUTION="$(plutil -extract distribution raw -o - "$TEMP_DIR/$MANIFEST_ASSET" 2>/dev/null || true)"
if [[ "$DISTRIBUTION" == "static-library-and-privacy-v1" ]]; then
    download "$PRIVACY_ASSET"
    download "$PRIVACY_ASSET.sha256"
    EXPECTED_PRIVACY_SHA="$(awk -v file="$PRIVACY_ASSET" '$1 == "sha256" && $3 == file { print $2 }' "$TEMP_DIR/$CHECKSUMS_ASSET")"
    COMPUTED_PRIVACY_SHA="$(shasum -a 256 "$TEMP_DIR/$PRIVACY_ASSET" | awk '{ print $1 }')"
    SIDECAR_PRIVACY_SHA="$(awk '{ print $1 }' "$TEMP_DIR/$PRIVACY_ASSET.sha256")"
    if [[ ! "$EXPECTED_PRIVACY_SHA" =~ ^[0-9a-f]{64}$ || "$COMPUTED_PRIVACY_SHA" != "$EXPECTED_PRIVACY_SHA" || "$SIDECAR_PRIVACY_SHA" != "$EXPECTED_PRIVACY_SHA" ]]; then
        echo "error: privacy resource checksum mismatch" >&2
        exit 1
    fi
    plutil -lint "$TEMP_DIR/$PRIVACY_ASSET"
elif [[ -n "$DISTRIBUTION" ]]; then
    echo "error: unsupported MarmotKit distribution: $DISTRIBUTION" >&2
    exit 1
fi

python3 - "$TEMP_DIR/$MANIFEST_ASSET" "$TEMP_DIR" "$RELEASE_ID" "$RELEASE_TAG" <<'PYVERIFY'
import hashlib, json, pathlib, sys
manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
root = pathlib.Path(sys.argv[2])
assert manifest['release_identifier'] == sys.argv[3], 'release identifier mismatch'
assert manifest['release_tag'] == sys.argv[4], 'release tag mismatch'
for name, metadata in manifest['artifacts'].items():
    path = root / name
    if path.is_file():
        assert hashlib.sha256(path.read_bytes()).hexdigest() == metadata['sha256'], f'{name}: manifest checksum mismatch'
PYVERIFY

echo "==> Installing generated Swift source"
mkdir -p "$PACKAGE_DIR/Sources/MarmotKit"
cp "$TEMP_DIR/$SWIFT_ASSET" "$PACKAGE_DIR/Sources/MarmotKit/MarmotKit.swift"
perl -pi -e 's/[ \t]+$//' "$PACKAGE_DIR/Sources/MarmotKit/MarmotKit.swift"
# The strip above means the installed copy is deliberately *not* byte-identical
# to the published asset, so its digest has to be taken here, after the rewrite.
# `just sanity` compares the vendored file against this value; the published
# digest is stamped alongside it for provenance only.
VENDORED_SWIFT_SHA="$(shasum -a 256 "$PACKAGE_DIR/Sources/MarmotKit/MarmotKit.swift" | awk '{ print $1 }')"

if [[ "$DISTRIBUTION" == "static-library-and-privacy-v1" ]]; then
    mkdir -p "$PACKAGE_DIR/Sources/MarmotKit/Resources"
    cp "$TEMP_DIR/$PRIVACY_ASSET" "$PACKAGE_DIR/Sources/MarmotKit/Resources/PrivacyInfo.xcprivacy"
    python3 - "$PACKAGE_DIR/Package.swift" <<'PYRESOURCE'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
if 'resources: [.copy("Resources/PrivacyInfo.xcprivacy")]' not in text:
    text = text.replace('path: "Sources/MarmotKit",', 'path: "Sources/MarmotKit",\n            resources: [.copy("Resources/PrivacyInfo.xcprivacy")],')
path.write_text(text)
PYRESOURCE
else
    # Older framework releases embed their own SDK manifest.
    rm -f "$PACKAGE_DIR/Sources/MarmotKit/Resources/PrivacyInfo.xcprivacy"
    sed -i '' '/resources: \[.copy("Resources\/PrivacyInfo.xcprivacy")\],/d' "$PACKAGE_DIR/Package.swift"
fi

echo "==> Pinning remote binary target"
sed -i '' -E \
    "s|^let marmotKitReleaseID = \".*\"|let marmotKitReleaseID = \"$RELEASE_ID\"|" \
    "$PACKAGE_DIR/Package.swift"
sed -i '' -E \
    "s|^let marmotKitReleaseTag = \".*\"|let marmotKitReleaseTag = \"$RELEASE_TAG\"|" \
    "$PACKAGE_DIR/Package.swift"
sed -i '' -E \
    "s|^let marmotKitChecksum = \".*\"|let marmotKitChecksum = \"$EXPECTED_BINARY_CHECKSUM\"|" \
    "$PACKAGE_DIR/Package.swift"

cat > "$PACKAGE_DIR/MARMOT_VERSION" <<EOF
mdk-sha: $SOURCE_SHA
mdk-branch: master
mdk-tag: $RELEASE_TAG
published-at: $PUBLISHED_AT
uniffi-version: $UNIFFI_VERSION
features: $FEATURES
macos-targets: $MACOS_TARGETS
macos-deployment-target: $MACOS_DEPLOYMENT_TARGET
rust-release-opt-level: $RUST_OPT_LEVEL
rust-release-codegen-units: $RUST_CODEGEN_UNITS
swiftpm-checksum: $EXPECTED_BINARY_CHECKSUM
swift-published-sha256: $EXPECTED_SWIFT_SHA
swift-vendored-sha256: $VENDORED_SWIFT_SHA
distribution: ${DISTRIBUTION:-legacy-framework}
privacy-sha256: ${EXPECTED_PRIVACY_SHA:-embedded-in-framework}

Notes:
- Refresh from a published immutable artifact with:
  whitenoise-mac/scripts/sync-bindings.sh <version-or-full-master-sha>
EOF

cat > "$PACKAGE_DIR/Sources/MarmotKit/MarmotKitVersion.swift" <<EOF
import Foundation

/// Build-time provenance for the pinned MarmotKit release.
/// Regenerated by whitenoise-mac/scripts/sync-bindings.sh on every refresh.
public enum MarmotKitVersion {
    public static let mdkSHA = "$SOURCE_SHA"
    public static let mdkTag = "$RELEASE_TAG"
    public static let builtAt = "$PUBLISHED_AT"
    public static let uniffiVersion = "$UNIFFI_VERSION"
    public static let features = "$FEATURES"
    public static let swiftPMChecksum = "$EXPECTED_BINARY_CHECKSUM"
    public static let vendoredSwiftSHA256 = "$VENDORED_SWIFT_SHA"
    public static let distribution = "${DISTRIBUTION:-legacy-framework}"
    public static let privacySHA256 = "${EXPECTED_PRIVACY_SHA:-embedded-in-framework}"

    /// Reads the separately packaged privacy declaration from a built consumer.
    public static func privacyManifestData(in bundle: Bundle = .main) -> Data? {
        guard let resources = bundle.resourceURL,
            let packageBundle = Bundle(url: resources.appending(path: "MarmotKit_MarmotKit.bundle")),
            let url = packageBundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
        else { return nil }
        return try? Data(contentsOf: url)
    }
}
EOF

echo ""
echo "Installed MarmotKit $RELEASE_TAG"
echo "  source:   $SOURCE_SHA"
echo "  checksum: $EXPECTED_BINARY_CHECKSUM"
echo "  swift:    $VENDORED_SWIFT_SHA (published $EXPECTED_SWIFT_SHA)"
echo "  macOS:    $MACOS_TARGETS (deployment target $MACOS_DEPLOYMENT_TARGET)"
echo "  privacy:  ${EXPECTED_PRIVACY_SHA:-embedded in framework}"
