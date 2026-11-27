#!/usr/bin/env bash
# Swap the pinned MarmotKit Release Candidate for the Stable release MDK promoted
# from it: the step that turns a tested staging build into a production one.
#
# MDK's promotion (promote-release.yml) builds Stable `marmotkit-vX.Y.Z` from a
# release commit whose only parent is the RC's verified source commit and whose
# only change is release metadata. This script pins that Stable release and
# refuses it unless its source is the pinned RC's source or a direct child of it,
# so production ships the code staging tested.
#
# Usage:
#   scripts/promote-stable.sh [X.Y.Z]
#
# The version defaults to the pinned RC's base version (0.20.0-rc.2 -> 0.20.0).
# Pass one when MDK promoted with an override version.

set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$APP_DIR/Vendored/MarmotKit/MARMOT_VERSION"

rc_tag="$(sed -nE 's/^mdk-tag: (.*)$/\1/p' "$VERSION_FILE")"
rc_sha="$(sed -nE 's/^mdk-sha: (.*)$/\1/p' "$VERSION_FILE")"
if [[ ! "$rc_tag" =~ ^marmotkit-v([0-9]+\.[0-9]+\.[0-9]+)-rc\.[0-9]+$ ]]; then
    echo "error: the pin is $rc_tag, not a Release Candidate; nothing to promote" >&2
    exit 1
fi
stable="${1:-${BASH_REMATCH[1]}}"
if [[ ! "$stable" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: $stable is not a Stable X.Y.Z version" >&2
    exit 2
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
cp "$APP_DIR/Vendored/MarmotKit/Sources/MarmotKit/MarmotKit.swift" "$TEMP_DIR/rc.swift"

# Check provenance before touching the pin.
manifest="marmotkit-macos-$stable.manifest.json"
curl --fail --location --retry 3 --silent --show-error \
    "https://github.com/marmot-protocol/mdk/releases/download/marmotkit-v$stable/$manifest" \
    --output "$TEMP_DIR/$manifest" \
    || { echo "error: no Stable marmotkit-v$stable release is published yet" >&2; exit 1; }
stable_sha="$(plutil -extract source_sha raw -o - "$TEMP_DIR/$manifest")"
if [[ "$stable_sha" != "$rc_sha" ]]; then
    curl --fail --location --retry 3 --silent --show-error \
        "https://api.github.com/repos/marmot-protocol/mdk/commits/$stable_sha" \
        --output "$TEMP_DIR/commit.json"
    parents="$(python3 -I -c 'import json, sys; print(" ".join(p["sha"] for p in json.load(open(sys.argv[1]))["parents"]))' "$TEMP_DIR/commit.json")"
    if [[ "$parents" != "$rc_sha" ]]; then
        echo "error: Stable $stable was built from $stable_sha, which is not $rc_tag's source $rc_sha" >&2
        echo "       or a release commit on it. MDK promoted a different RC: pin that RC on develop," >&2
        echo "       cut and test a staging build from it, then promote again." >&2
        exit 1
    fi
fi
echo "==> Stable $stable comes from $rc_tag ($rc_sha)"

"$APP_DIR/scripts/sync-bindings.sh" "$stable"

# The generated Swift should differ by version strings at most.
changed="$(diff "$TEMP_DIR/rc.swift" "$APP_DIR/Vendored/MarmotKit/Sources/MarmotKit/MarmotKit.swift" | grep -c '^[<>]' || true)"
echo ""
echo "Generated Swift lines changed from $rc_tag: $changed"
