#!/usr/bin/env bash
# Build and switch to an experimental device-group MarmotKit for testing device linking.
#
# Published MarmotKit releases are built without MDK's `dev-device-groups` feature, so every
# linking call is refused (`experimental_device_groups_unavailable`). This script builds the
# same mdk commit the app is pinned to (Vendored/MarmotKit/MARMOT_VERSION) with that feature,
# and points the local Swift package at the result. It never touches production: a Release
# build refuses the experimental runtime (`MarmotClient`), and `just sanity` fails while the
# package is switched, so a switched Package.swift cannot be committed by accident.
#
# Usage:
#   scripts/dev-device-groups.sh build     # build the capable library (slow: a full release build)
#   scripts/dev-device-groups.sh use       # point Vendored/MarmotKit at it
#   scripts/dev-device-groups.sh restore   # back to the pinned published release
#   scripts/dev-device-groups.sh status
#
# MDK_DIR (default: ../mdk next to this repo) is the mdk clone to build from. The build runs in
# a detached worktree under build/dev-device-groups/, so the clone's own checkout is untouched.
# MDK_SHA (default: the pinned mdk-sha) builds another full commit instead, for an ad-hoc test of
# unreleased MDK; set it for `use` and `status` too. MDK commits from mdk#3476 on have no
# `dev-device-groups` feature (device groups are always built in), so the flag is passed only to a
# commit whose build script still has it.

set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$APP_DIR/Vendored/MarmotKit"
WORK_DIR="$APP_DIR/build/dev-device-groups"
MDK_DIR="${MDK_DIR:-$(cd "$APP_DIR/.." && pwd)/mdk}"
LOCAL_FRAMEWORK="MarmotKitFFI-dev-device-groups.xcframework"

pinned_sha() {
    if [[ -n "${MDK_SHA:-}" ]]; then
        echo "$MDK_SHA"
    else
        sed -n 's/^mdk-sha: //p' "$PACKAGE_DIR/MARMOT_VERSION"
    fi
}

# Whether this commit's macOS build script still has the explicit opt-in.
has_dev_flag() {
    grep -q -- '--dev-device-groups' "$(worktree_dir)/crates/marmot-uniffi/xcframework-macos.sh"
}

worktree_dir() {
    echo "$WORK_DIR/mdk-$(pinned_sha)"
}

output_dir() {
    if has_dev_flag 2>/dev/null; then
        echo "$(worktree_dir)/crates/marmot-uniffi/output-dev-device-groups/macos"
    else
        echo "$(worktree_dir)/crates/marmot-uniffi/output/macos"
    fi
}

# The vendored copy has trailing whitespace stripped (sync-bindings.sh), so compare ignoring it.
same_bindings() {
    diff -q -w -B "$1" "$PACKAGE_DIR/Sources/MarmotKit/MarmotKit.swift" >/dev/null
}

is_switched() {
    grep -q "$LOCAL_FRAMEWORK" "$PACKAGE_DIR/Package.swift"
}

cmd_build() {
    local sha tree
    sha="$(pinned_sha)"
    tree="$(worktree_dir)"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "error: no mdk-sha in MARMOT_VERSION" >&2; exit 1; }
    [[ -d "$MDK_DIR/.git" ]] || { echo "error: no mdk clone at $MDK_DIR (set MDK_DIR)" >&2; exit 1; }

    if ! git -C "$MDK_DIR" cat-file -e "$sha^{commit}" 2>/dev/null; then
        echo "==> Fetching $sha into $MDK_DIR"
        git -C "$MDK_DIR" fetch --quiet origin "$sha"
    fi
    if [[ ! -d "$tree" ]]; then
        echo "==> Creating detached mdk worktree at $sha"
        mkdir -p "$WORK_DIR"
        git -C "$MDK_DIR" worktree add --detach "$tree" "$sha"
    fi

    # Match the published release's features so only device groups differ.
    echo "==> Building the dev-device-groups macOS XCFramework (this takes a while)"
    local flag=()
    if has_dev_flag; then flag=(--dev-device-groups); fi
    OTLP_EXPORT=1 PRODUCT_ANALYTICS_EXPORT=1 \
        "$tree/crates/marmot-uniffi/xcframework-macos.sh" ${flag[@]+"${flag[@]}"}

    local out
    out="$(output_dir)"
    if same_bindings "$out/MarmotKit.swift"; then
        echo "==> Generated Swift matches the vendored bindings"
    else
        echo "==> Generated Swift differs from the vendored bindings; 'use' installs it alongside the library"
    fi
    echo "Built $out/MarmotKit.xcframework. Run '$0 use' to switch to it."
}

cmd_use() {
    local out
    out="$(output_dir)"
    [[ -d "$out/MarmotKit.xcframework" ]] || { echo "error: nothing built; run '$0 build' first" >&2; exit 1; }

    rm -rf "${PACKAGE_DIR:?}/$LOCAL_FRAMEWORK"
    cp -R "$out/MarmotKit.xcframework" "$PACKAGE_DIR/$LOCAL_FRAMEWORK"

    if ! is_switched; then
        # Replace the remote binary target with the local one. Restored from git by `restore`.
        perl -0pi -e 's/\.binaryTarget\(\s*name: "MarmotKitFFI",\s*url: marmotKitBinaryURL,\s*checksum: marmotKitChecksum\s*\)/.binaryTarget(name: "MarmotKitFFI", path: "'"$LOCAL_FRAMEWORK"'")/s' \
            "$PACKAGE_DIR/Package.swift"
        is_switched || { echo "error: could not rewrite Package.swift" >&2; exit 1; }
    fi
    if ! same_bindings "$out/MarmotKit.swift"; then
        cp "$out/MarmotKit.swift" "$PACKAGE_DIR/Sources/MarmotKit/MarmotKit.swift"
        echo "==> Installed the matching generated Swift"
    fi
    echo "Switched to the experimental device-group MarmotKit. Debug and staging builds now open"
    echo "with device groups on; run '$0 restore' before committing."
}

cmd_restore() {
    git -C "$APP_DIR" checkout -- Vendored/MarmotKit/Package.swift Vendored/MarmotKit/Sources/MarmotKit/MarmotKit.swift
    rm -rf "${PACKAGE_DIR:?}/$LOCAL_FRAMEWORK"
    echo "Restored the pinned published MarmotKit."
}

cmd_status() {
    echo "pinned mdk: $(pinned_sha)"
    if [[ -d "$(output_dir)/MarmotKit.xcframework" ]]; then
        echo "built:      $(output_dir)/MarmotKit.xcframework"
    else
        echo "built:      no"
    fi
    if is_switched; then echo "package:    experimental device groups"; else echo "package:    published release"; fi
}

case "${1:-}" in
    build) cmd_build ;;
    use) cmd_use ;;
    restore) cmd_restore ;;
    status) cmd_status ;;
    *) echo "usage: $0 build|use|restore|status" >&2; exit 2 ;;
esac
