#!/usr/bin/env bash
#
# Report untranslated strings in the project's Xcode String Catalogs.
#
# Xcode shows a per-language completion bar in the String Catalog editor, but
# ships no command-line equivalent: `xcrun xcstringstool` only knows print,
# compile, sync and generate-symbols, its `compile` accepts an incomplete
# catalog (and even a dangling `%#@token@`) without complaint, and a normal
# build never fails on an untranslated string. This script is that missing
# check -- the String Catalog counterpart of the sibling Flutter repo's
# `scripts/validate-locales-keys.sh`.
#
# For every key in every `*.xcstrings` file it verifies that each language the
# project declares (`knownRegions` in project.pbxproj) has a non-empty,
# `translated` value, including inside plural `substitutions`.
#
# Errors (exit code 1):
#   missing       language has no entry at all for the key
#   untranslated  entry exists but is `state: "new"` or has an empty value
#   stale         source string no longer exists in code (`extractionState`)
#   plural        a substitution or one of its plural categories is absent/empty
#   unknown-lang  catalog carries a language the project does not declare
#
# Warnings (exit code 0, or 1 with --strict):
#   needs-review  entry is `state: "needsReview"`
#
# Keys with `shouldTranslate: false` are skipped, as are keys with no
# translatable content -- ones that are only format specifiers, digits,
# punctuation or whitespace, such as "%lld / %lld" or "99+". Use --verbose to
# list what was skipped.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PROJECT_FILE="whitenoise-mac.xcodeproj/project.pbxproj"

# Regions in `knownRegions` that are not translation targets.
NON_LANGUAGE_REGION="Base"

STRICT=0
SHOW_ALL=0
VERBOSE=0
MAX_ISSUES=15
LANGUAGES=()
CATALOGS=()

fail() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: check-localizations.sh [options] [catalog ...]

Check Xcode String Catalogs for untranslated strings. Without arguments every
*.xcstrings file in the repo is checked. Exits 1 when any language is incomplete.

options:
  --language CODE   check only this language (repeatable); default is knownRegions
  --strict          treat needsReview as an error
  --all             list every issue, not just the first few
  --max-issues N    issues listed per language before truncating (default: 15)
  --verbose         also list skipped keys
  -h, --help        show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --language)
      [[ $# -ge 2 ]] || fail "--language needs a language code"
      LANGUAGES+=("$2")
      shift 2
      ;;
    --strict) STRICT=1 && shift ;;
    --all) SHOW_ALL=1 && shift ;;
    --verbose) VERBOSE=1 && shift ;;
    --max-issues)
      [[ ${2:-} =~ ^[0-9]+$ ]] || fail "--max-issues needs a number"
      MAX_ISSUES="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) fail "unknown option: $1 (try --help)" ;;
    *)
      CATALOGS+=("$1")
      shift
      ;;
  esac
done

command -v jq >/dev/null || fail "jq is required but was not found in PATH"

# The languages listed in the project's knownRegions, one per line.
project_languages() {
  awk -v skip="$NON_LANGUAGE_REGION" '
    /knownRegions[[:space:]]*=/ { inside = 1; next }
    inside && /\);/ { exit }
    inside {
      gsub(/[",]/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if ($0 != "" && $0 != skip) print
    }
  ' "$1"
}

discover_catalogs() {
  find . \
    -type d \( -name trees -o -name Vendored -o -name build -o -name .build \
    -o -name DerivedData -o -name .git \) -prune \
    -o -name '*.xcstrings' -print |
    sed 's|^\./||' |
    sort
}

if [[ ${#CATALOGS[@]} -eq 0 ]]; then
  while IFS= read -r found; do
    CATALOGS+=("$found")
  done < <(discover_catalogs)
  [[ ${#CATALOGS[@]} -gt 0 ]] || fail "no .xcstrings catalogs found"
fi

# `EXHAUSTIVE` means the language list is the project's whole set, so a catalog
# carrying anything outside it is a mistake. An explicit --language list only
# narrows what gets checked and says nothing about the rest.
EXHAUSTIVE=true
if [[ ${#LANGUAGES[@]} -eq 0 ]]; then
  if [[ -r "$PROJECT_FILE" ]]; then
    while IFS= read -r language; do
      LANGUAGES+=("$language")
    done < <(project_languages "$PROJECT_FILE")
  fi
  if [[ ${#LANGUAGES[@]} -eq 0 ]]; then
    echo "warning: could not read knownRegions from $PROJECT_FILE;" \
      "falling back to the languages present in each catalog" >&2
    EXHAUSTIVE=false
  fi
else
  EXHAUSTIVE=false
fi

if [[ ${#LANGUAGES[@]} -eq 0 ]]; then
  LANGUAGES_JSON=null
else
  LANGUAGES_JSON="$(printf '%s\n' "${LANGUAGES[@]}" | jq -R . | jq -sc .)"
fi

# Emits one tab-separated record per line: kind, then up to four fields.
#   source <> <language>              the catalog's source language
#   stat   <name> <count>             total / checked / skipped / opted-out
#   lang   <> <language>              one per language checked, in order
#   skip   <> <> <key>                key skipped as untranslatable
#   issue  <kind> <language> <key> <detail>
# Issues come out sorted: errors before warnings, then by language and key.
JQ_PROGRAM="$(
  cat <<'JQ'
# Drop printf-style specifiers and String Catalog substitution tokens.
def strip_format:
  gsub("%#@[^@]+@"; "")
  | gsub("%([0-9]+\\$)?[-+ #0']*[0-9*]*(\\.[0-9]+)?(hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGaAcCsSpn%]"; "");

# Does this text contain an actual word, or only format specifiers and punctuation?
def has_words: strip_format | test("\\p{L}");

# Classify a stringUnit: empty string when fine, else the issue kind.
def unit_issue:
  if (type != "object") then "missing"
  elif (((.value // "") | test("\\S")) | not) then "untranslated"
  elif .state == "new" then "untranslated"
  elif .state == "needsReview" then "needs-review"
  elif .state != "translated" then "untranslated"
  else "" end;

# Every plural leaf of one localization, as {path, unit}.
def plural_leaves:
  [ (.substitutions // {}) | to_entries[] as $sub
    | (($sub.value.variations // {}) | to_entries[]) as $variation
    | ($variation.value | to_entries[]) as $category
    | { path: "\($sub.key).\($variation.key).\($category.key)",
        unit: $category.value.stringUnit } ]
  | sort_by(.path)[];

def language_issues($entry; $key; $language; $source_subs):
  ($entry.localizations[$language]) as $loc
  | if ($loc | type) != "object" then
      [ { kind: "missing", detail: "" } ]
    else
      [ ($loc.stringUnit | unit_issue) | select(. != "") | { kind: ., detail: "" } ]
      + [ ($source_subs - (($loc.substitutions // {}) | keys))[]
          | { kind: "plural", detail: "substitution %#@\(.)@ is missing" } ]
      + [ $loc | plural_leaves | (.unit | unit_issue) as $kind
          | select($kind != "")
          | { kind: "plural", detail: "\(.path) is \($kind)" } ]
      + [ (($loc.substitutions // {}) | to_entries[])
          | select((.value.variations.plural | type) == "object"
                   and (.value.variations.plural | has("other") | not))
          | { kind: "plural", detail: "\(.key).plural has no 'other' category" } ]
    end
  | map([ "issue", .kind, $language, $key, .detail ]);

(.sourceLanguage // "en") as $source
| (.strings // {}) as $strings
| ([ $strings[] | (.localizations // {}) | keys[] ] | unique - [$source]) as $present
| (if $languages == null then $present else ($languages - [$source]) end) as $langs
# Classify every key once: opted out, skipped as untranslatable, or checked.
| [ $strings
    | to_entries[]
    | . as { key: $key, value: $entry }
    | { key: $key,
        entry: $entry,
        class:
          (if $entry.shouldTranslate == false then "opted-out"
           elif (($key | has_words)
                 or (($entry.localizations[$source].stringUnit.value // "") | has_words)) then "checked"
           else "skipped" end) } ] as $entries
| [ $entries[] | select(.class == "checked") ] as $checked
| ( [ "source", "", $source ],
    [ "stat", "total", ($strings | length) ],
    [ "stat", "checked", ($checked | length) ],
    [ "stat", "skipped", ([ $entries[] | select(.class == "skipped") ] | length) ],
    [ "stat", "opted-out", ([ $entries[] | select(.class == "opted-out") ] | length) ],
    ( $langs[] | [ "lang", "", . ] ),
    ( $entries[] | select(.class == "skipped") | [ "skip", "", "", .key ] ),
    ( [ ( if $exhaustive then
            ($present - $langs)[] | [ [ "issue", "unknown-lang", ., "", "not listed in knownRegions" ] ]
          else empty end ),
        ( $checked[]
          | .key as $key
          | .entry as $entry
          | ( if $entry.extractionState == "stale" then
                [ [ "issue", "stale", "-", $key, "source string no longer found in code" ] ]
              else empty end ),
            ( (($entry.localizations[$source].substitutions // {}) | keys) as $source_subs
              | $langs[]
              | language_issues($entry; $key; .; $source_subs) ) ) ]
      | add // []
      | sort_by([ (if .[1] == "needs-review" then 1 else 0 end), .[2], .[3], .[4] ])[] ) )
| @tsv
JQ
)"

# Turns those records into the human-readable report; exits 1 when the catalog fails.
REPORT_PROGRAM='
function pad(text, width,   out) {
  out = text
  while (length(out) < width) out = out " "
  return out
}
$1 == "source" { source_language = $3; next }
$1 == "stat"   { stat[$2] = $3 + 0; next }
$1 == "lang"   { order[++languages] = $3; next }
$1 == "skip"   { skipped[++skips] = $4; next }
$1 == "issue" {
  count = ++issues
  label = ($2 == "needs-review") ? "warning" : "error"
  group = label FS $3
  kind[count] = $2
  key[count] = $4
  detail[count] = $5
  grp[count] = group
  size[group]++
  if (label == "warning") {
    warnings++
  } else {
    errors++
    # A key counts against a language once, however many ways it is broken.
    if (!(($3 SUBSEP $4) in broken)) {
      broken[$3, $4] = 1
      incomplete[$3]++
    }
  }
  next
}
END {
  printf "=== %s ===\n", catalog
  printf "Source language: %s\n", source_language
  printf "Keys: %d total, %d translatable (%d format-only, %d marked do-not-translate)\n\n",
    stat["total"], stat["checked"], stat["skipped"], stat["opted-out"]

  width = 0
  for (i = 1; i <= languages; i++) {
    if (length(order[i]) > width) width = length(order[i])
  }
  for (i = 1; i <= languages; i++) {
    language = order[i]
    done = stat["checked"] - incomplete[language]
    gap = stat["checked"] - done
    percent = (stat["checked"] == 0) ? 100 : done * 100 / stat["checked"]
    printf "  %s %s  %d/%d (%5.1f%%)%s\n",
      (gap ? "\342\235\214" : "\342\234\205"), pad(language, width), done, stat["checked"], percent,
      (gap ? sprintf("  -- %d missing", gap) : "")
  }

  if (skips > 0 && verbose == 1) {
    printf "\n  Skipped as not translatable:\n"
    for (i = 1; i <= skips; i++) printf "    - \"%s\"\n", skipped[i]
  }

  for (i = 1; i <= issues; i++) {
    split(grp[i], parts, FS)
    if (grp[i] != previous_group) {
      if (parts[1] != previous_label) printf "\n"
      printf "  %s: %s: %d issue(s)\n", parts[1], parts[2], size[grp[i]]
      shown = 0
      previous_group = grp[i]
      previous_label = parts[1]
    }
    if (show_all == 1 || shown < max_issues) {
      text = (key[i] == "") ? "" : "\"" key[i] "\""
      if (detail[i] != "") text = (text == "") ? detail[i] : text " -- " detail[i]
      printf "    [%s] %s\n", kind[i], text
      shown++
    } else if (!(grp[i] in noted)) {
      noted[grp[i]] = 1
      printf "    ... and %d more (pass --all to list them)\n", size[grp[i]] - max_issues
    }
  }

  printf "\n"
  if (errors > 0 || (strict == 1 && warnings > 0)) exit 1
}
'

RECORDS="$(mktemp)"
trap 'rm -f "$RECORDS"' EXIT

passed=1
total_warnings=0
for catalog in "${CATALOGS[@]}"; do
  [[ -r "$catalog" ]] || fail "no such catalog: $catalog"
  jq -r --argjson languages "$LANGUAGES_JSON" --argjson exhaustive "$EXHAUSTIVE" \
    "$JQ_PROGRAM" "$catalog" >"$RECORDS" ||
    fail "$catalog is not a readable String Catalog"

  total_warnings=$((total_warnings + $(grep -c "$(printf 'issue\tneeds-review')" "$RECORDS" || true)))

  awk -F'\t' \
    -v catalog="$catalog" \
    -v strict="$STRICT" \
    -v show_all="$SHOW_ALL" \
    -v verbose="$VERBOSE" \
    -v max_issues="$MAX_ISSUES" \
    "$REPORT_PROGRAM" "$RECORDS" || passed=0
done

if [[ $passed -eq 1 ]]; then
  if [[ $total_warnings -gt 0 ]]; then
    echo "✅ All languages are fully translated ($total_warnings needs-review warning(s))."
  else
    echo "✅ All languages are fully translated."
  fi
  exit 0
fi

echo "❌ Localization check failed. Open the catalog in Xcode to fill the gaps."
exit 1
