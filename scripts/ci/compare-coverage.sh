#!/usr/bin/env bash
#
# Compare a coverage percentage against the baseline measured on master.
#
# The measuring half of this pair (`coverage.sh`) needs Xcode and the result
# bundle; this half needs neither, so the two run on different machines: the
# number is produced on the macOS runner that already has the bundle in hand,
# and the comparison happens wherever it is cheapest. Keeping the comparison in
# a script rather than in workflow YAML also keeps it runnable and testable by
# hand, and keeps `${{ }}` values out of a shell command line.
#
# A missing baseline is not a failure. It is the ordinary state of a repository
# whose master has not published a coverage artifact yet -- on the first run
# after this check lands, and again whenever the last successful master run has
# aged past the artifact retention window. Reporting the number and passing is
# the only behavior that does not block every PR in those windows.
#
# Usage:
#   compare-coverage.sh --current 42.10 --baseline 41.90
#   compare-coverage.sh --current pr/coverage.txt --baseline master/coverage.txt
#
# Either value may be given as a literal percentage or as a path to a file
# holding one. Writes a Markdown summary to $GITHUB_STEP_SUMMARY when that is
# set, and exits 1 when coverage fell by more than --tolerance.

set -euo pipefail

CURRENT_ARG=""
BASELINE_ARG=""
UNCOVERED_FILE=""

# Long enough to be worth acting on, short enough that the summary stays a
# summary; the rest are named in the "Measure code coverage" step's log.
MAX_LISTED=25

# Line coverage is deterministic for a fixed source tree and a fixed test plan,
# but not perfectly so: a test whose timing decides whether a branch runs moves
# the number by a hundredth or two between runs. The tolerance absorbs that and
# nothing larger -- a real regression is a whole file or function going
# untested, which is orders of magnitude above this.
TOLERANCE="0.10"

fail() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: compare-coverage.sh --current VALUE [--baseline VALUE] [--tolerance T]

Compare a coverage percentage against a baseline and report the delta. VALUE is
either a literal percentage or a path to a file containing one.

options:
  --current VALUE     coverage measured on this run (required)
  --baseline VALUE    coverage measured on master; absent means "no baseline"
  --tolerance T       allowed drop in percentage points (default 0.10)
  --uncovered-file F  file listing 0%-covered sources, appended to the summary
  -h, --help          show this message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --current)
      [[ $# -ge 2 ]] || fail "--current needs a value"
      CURRENT_ARG="$2"
      shift 2
      ;;
    --baseline)
      [[ $# -ge 2 ]] || fail "--baseline needs a value"
      BASELINE_ARG="$2"
      shift 2
      ;;
    --tolerance)
      [[ $# -ge 2 ]] || fail "--tolerance needs a value"
      TOLERANCE="$2"
      shift 2
      ;;
    --uncovered-file)
      [[ $# -ge 2 ]] || fail "--uncovered-file needs a path"
      UNCOVERED_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

is_percentage() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

# A value that names a readable file is read from it; anything else is taken
# literally. An unreadable path and a malformed file both come back empty,
# which the caller treats as "no value" rather than as zero -- scoring a failed
# artifact download as 0% would turn every such hiccup into a false pass.
read_percentage() {
  local value="$1" text
  if [[ -f "$value" ]]; then
    text="$(tr -d '[:space:]' < "$value")"
  else
    text="$value"
  fi
  if is_percentage "$text"; then
    printf '%s\n' "$text"
  fi
}

[[ -n "$CURRENT_ARG" ]] || fail "--current is required"
is_percentage "$TOLERANCE" || fail "--tolerance must be a number, got '$TOLERANCE'"

CURRENT="$(read_percentage "$CURRENT_ARG")"
[[ -n "$CURRENT" ]] || fail "could not read a percentage from --current '$CURRENT_ARG'"

BASELINE=""
if [[ -n "$BASELINE_ARG" ]]; then
  BASELINE="$(read_percentage "$BASELINE_ARG")"
fi

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    cat >> "$GITHUB_STEP_SUMMARY"
  else
    cat
  fi
}

# Collapsed rather than inline: it is reference material for whoever is adding
# the tests, not something every reader of the run needs to scroll past.
append_uncovered() {
  local count
  [[ -n "$UNCOVERED_FILE" && -s "$UNCOVERED_FILE" ]] || return 0
  count="$(wc -l < "$UNCOVERED_FILE" | tr -d ' ')"
  {
    echo ""
    echo "<details><summary>${count} file(s) with 0% coverage</summary>"
    echo ""
    # shellcheck disable=SC2016  # $ is sed's end-of-line anchor, not a variable.
    head -n "$MAX_LISTED" "$UNCOVERED_FILE" | sed 's/^/- `/; s/$/`/'
    if [[ "$count" -gt "$MAX_LISTED" ]]; then
      echo ""
      echo "_... and $((count - MAX_LISTED)) more._"
    fi
    echo ""
    echo "</details>"
  } | summary
}

if [[ -z "$BASELINE" ]]; then
  echo "coverage: ${CURRENT}% (no master baseline to compare against)"
  summary <<EOF
## Coverage

**${CURRENT}%**

No master baseline was available, so there is nothing to compare against. This
run's number becomes the baseline once it lands on master.
EOF
  append_uncovered
  exit 0
fi

DIFF="$(awk -v c="$CURRENT" -v b="$BASELINE" 'BEGIN { printf "%+.2f", c - b }')"

if awk -v c="$CURRENT" -v b="$BASELINE" -v t="$TOLERANCE" 'BEGIN { exit !(c < b - t) }'; then
  VERDICT="regressed"
  ICON=":x:"
elif awk -v c="$CURRENT" -v b="$BASELINE" 'BEGIN { exit !(c > b) }'; then
  VERDICT="improved"
  ICON=":white_check_mark:"
else
  VERDICT="held"
  ICON=":white_check_mark:"
fi

summary <<EOF
## Coverage

| master | this run | delta | |
| ---: | ---: | ---: | :--- |
| ${BASELINE}% | ${CURRENT}% | ${DIFF} pp | ${ICON} ${VERDICT} |
EOF

append_uncovered

if [[ "$VERDICT" == "regressed" ]]; then
  echo "::error::Coverage fell from ${BASELINE}% to ${CURRENT}% (${DIFF} pp). Add tests for the new code, or mark genuinely untestable files with '// coverage:ignore-file'."
  exit 1
fi

echo "coverage: ${CURRENT}% vs master ${BASELINE}% (${DIFF} pp, ${VERDICT})"
