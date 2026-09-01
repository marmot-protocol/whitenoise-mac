#!/usr/bin/env bash
#
# Report Swift line coverage for the app target from an .xcresult bundle.
#
# Xcode writes coverage into the result bundle but offers no threshold check of
# its own: `xcodebuild test -enableCodeCoverage YES` records the numbers and a
# green run says nothing about them. This script is that missing check -- the
# xccov counterpart of the sibling iOS repo's `scripts/check-coverage.sh` and,
# through it, of the Flutter repo's lcov-based script of the same name.
#
# What counts:
#   * only first-party source under the roots in SOURCE_ROOTS -- the generated
#     MarmotKit bindings and the test bundle are separate targets and drop out
#     on the target and path filters below;
#   * only files xccov actually reported. A first-party file it never mentions
#     is compiled into no instrumented target, which is a project problem
#     rather than a testing one, so it is warned about and left out of the
#     denominator instead of silently scoring 0%;
#   * everything except files whose first lines carry `// coverage:ignore-file`.
#
# Usage:
#   coverage.sh                             # print line coverage %, nothing else
#   coverage.sh --min 40                    # additionally exit 1 below 40%
#   coverage.sh --output coverage.txt       # also write the bare % to a file
#   coverage.sh --warnings-file out.txt     # list 0%-covered files to a file
#   coverage.sh path/to/Other.xcresult      # read a non-default result bundle

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# Matches `just test` and the "Unit tests" CI step, both of which write here.
XCRESULT="TestResults.xcresult"
MIN_COVERAGE=""
WARNINGS_FILE=""
OUTPUT_FILE=""

# Defined once and reused by the jq path filter, the relativizer and the
# not-instrumented sweep, so the three can never disagree about what is
# first-party.
SOURCE_ROOTS=(whitenoise-mac)
IGNORE_MARKER="// coverage:ignore-file"

# A long list of uninstrumented or uncovered files is a finding in itself, not
# something to page through in a CI log; past this many the tail is summarised.
MAX_LISTED=20

fail() {
  echo "error: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
}

usage() {
  cat <<'EOF'
usage: coverage.sh [options] [result-bundle]

Print Swift line coverage for first-party source in an .xcresult bundle.
Defaults to ./TestResults.xcresult, the bundle `just test` produces.

options:
  --min PERCENT         exit 1 when coverage is below PERCENT
  --output FILE         write the bare percentage to FILE as well as stdout
  --warnings-file FILE  write the list of 0%-covered files to FILE
  -h, --help            show this message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --min)
      [[ $# -ge 2 ]] || fail "--min needs a percentage"
      MIN_COVERAGE="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || fail "--output needs a path"
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --warnings-file)
      [[ $# -ge 2 ]] || fail "--warnings-file needs a path"
      WARNINGS_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      XCRESULT="$1"
      shift
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq not found; install it with 'brew install jq'"
command -v xcrun >/dev/null 2>&1 || fail "xcrun not found; this script needs Xcode's command line tools"
[[ -e "$XCRESULT" ]] || fail "$XCRESULT not found; run 'just test' first"

if ! REPORT_JSON="$(xcrun xccov view --report --json "$XCRESULT" 2>/dev/null)"; then
  fail "no coverage data in $XCRESULT; was it produced with -enableCodeCoverage YES?"
fi

# xccov reports absolute paths from the machine that ran the tests. Turning one
# back into a repo-relative path by regex is a trap here: the checkout on a
# GitHub runner is itself named `whitenoise-mac`, so a leftmost match on
# `/whitenoise-mac/` in `/Users/runner/work/whitenoise-mac/whitenoise-mac/...`
# picks the wrapper directory and every path it yields is wrong. Strip the
# known root instead, and only fall back to a rightmost match -- checked
# against the working tree -- for a bundle produced in some other checkout.
relativize() {
  local abs="$1" rel root
  rel="${abs#"$ROOT_DIR"/}"
  if [[ "$rel" != "$abs" ]]; then
    printf '%s\n' "$rel"
    return 0
  fi
  for root in "${SOURCE_ROOTS[@]}"; do
    rel="${abs##*/"$root"/}"
    if [[ "$rel" != "$abs" && -f "$root/$rel" ]]; then
      printf '%s/%s\n' "$root" "$rel"
      return 0
    fi
  done
  return 1
}

ROOTS_ALT="$(IFS='|'; printf '%s' "${SOURCE_ROOTS[*]}")"

# path<TAB>coveredLines<TAB>executableLines, first-party targets only. The test
# bundle is excluded by name as well as by path: the PR test plan already scopes
# coverage to the app target, but nothing in the bundle records that it did.
# shellcheck disable=SC2016  # $roots is a jq variable, bound with --arg below.
JQ_PROG='
  .targets[]
  | select((.name // "") | ascii_downcase | contains("test") | not)
  | .files[]
  | select(.path | test("/(" + $roots + ")/"))
  | select((.path | test("\\.xcassets/")) | not)
  | [ .path, (.coveredLines // 0), (.executableLines // 0) ]
  | @tsv
'

reported_file="$(mktemp)"
uncovered_file="$(mktemp)"
trap 'rm -f "$reported_file" "$uncovered_file"' EXIT

covered=0
executable=0
unrelocatable=0

while IFS=$'\t' read -r abs cov exe; do
  [[ -n "$abs" ]] || continue

  if ! rel="$(relativize "$abs")"; then
    unrelocatable=$((unrelocatable + 1))
    continue
  fi

  # The marker only ever sits in a header comment; reading the whole file to
  # find it would mean opening every source file in the project.
  if head -n 20 "$rel" 2>/dev/null | grep -qF "$IGNORE_MARKER"; then
    continue
  fi

  printf '%s\n' "$rel" >> "$reported_file"
  covered=$((covered + cov))
  executable=$((executable + exe))

  if [[ "$cov" -eq 0 && "$exe" -gt 0 ]]; then
    printf '%s\n' "$rel" >> "$uncovered_file"
  fi
done < <(printf '%s' "$REPORT_JSON" | jq -r --arg roots "$ROOTS_ALT" "$JQ_PROG")

if [[ "$unrelocatable" -gt 0 ]]; then
  warn "$unrelocatable covered file(s) in $XCRESULT do not resolve to this checkout and were skipped"
fi

[[ "$executable" -gt 0 ]] || fail "no first-party coverage found in $XCRESULT under: ${SOURCE_ROOTS[*]}"

# Warn-only sweep for first-party source xccov never mentioned. Counting these
# as 0% would let a target-membership mistake read as a testing regression, and
# the two want different fixes.
uninstrumented=0
while IFS= read -r swift; do
  case "$swift" in *.xcassets/*) continue ;; esac
  head -n 20 "$swift" 2>/dev/null | grep -qF "$IGNORE_MARKER" && continue
  grep -qxF "$swift" "$reported_file" && continue
  uninstrumented=$((uninstrumented + 1))
  if [[ "$uninstrumented" -eq 1 ]]; then
    warn "first-party file(s) not instrumented -- not counted in the total:"
  fi
  if [[ "$uninstrumented" -le "$MAX_LISTED" ]]; then
    warn "   $swift"
  fi
done < <(find "${SOURCE_ROOTS[@]}" -name '*.swift' -type f 2>/dev/null | sort)

if [[ "$uninstrumented" -gt "$MAX_LISTED" ]]; then
  warn "   ... and $((uninstrumented - MAX_LISTED)) more"
fi

COVERAGE="$(awk -v c="$covered" -v e="$executable" 'BEGIN { printf "%.2f", c / e * 100 }')"

if [[ -s "$uncovered_file" ]]; then
  count="$(wc -l < "$uncovered_file" | tr -d ' ')"
  warn "$count instrumented file(s) with 0% coverage"
fi

if [[ -n "$WARNINGS_FILE" ]]; then
  mkdir -p "$(dirname "$WARNINGS_FILE")"
  sort "$uncovered_file" > "$WARNINGS_FILE"
fi

if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  printf '%s\n' "$COVERAGE" > "$OUTPUT_FILE"
fi

echo "$COVERAGE"

if [[ -n "$MIN_COVERAGE" ]]; then
  if ! awk -v got="$COVERAGE" -v min="$MIN_COVERAGE" 'BEGIN { exit !(got >= min) }'; then
    echo "error: coverage ${COVERAGE}% is below the required ${MIN_COVERAGE}%" >&2
    exit 1
  fi
fi
