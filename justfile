# Local mirror of .github/workflows/mac-ci.yml.
# Keep the recipes below in sync with that workflow so `just precommit`
# stays a faithful predictor of the GitHub Actions result.
#
# CI runs these as four independent jobs in parallel; `just precommit` runs the
# same work serially, cheapest-first, so a formatting slip fails in seconds
# instead of after a Release build. The recipes map one-to-one:
#
#   CI job "Static checks"   -> just checks   (lint, locales, sanity)
#   CI job "Unit tests"      -> just test
#   CI job "Release build"   -> just build-release
#   CI job "Static analysis" -> just analyze
#   CI job "Coverage"        -> just coverage
#
# `just coverage` mirrors only the measuring half of that job. CI additionally
# compares the number against master's, which needs a baseline that lives in a
# GitHub Actions artifact -- so a green `just precommit` predicts the coverage
# figure CI will print, not the verdict it will reach on the delta.
#
# CI's "PR Checks" is only an aggregate gate over the five; it has no local
# counterpart beyond `just precommit` itself.

PROJECT := "whitenoise-mac.xcodeproj"
SCHEME := "whitenoise-mac"
DESTINATION := "platform=macOS"

# Source roots checked by swift-format (matches the "Swift format lint" CI step).
SWIFT_PATHS := "whitenoise-mac whitenoise-macTests whitenoise-macUITests"

default: precommit

# List available recipes
help:
    @just --list

# Run everything CI runs on a PR — all five jobs, serially
precommit: checks test build-release analyze coverage
    @echo ""
    @echo "✅ precommit passed — mac-ci.yml should be green."

# CI job: Static checks — the three checks that need no compile of their own
checks: lint locales sanity

# CI step: Swift format lint (strict — warnings fail the build)
lint:
    xcrun swift-format lint \
        --configuration .swift-format \
        --recursive \
        --parallel \
        --strict \
        {{SWIFT_PATHS}}

# Rewrite sources in place to satisfy `just lint`
autofix:
    xcrun swift-format format \
        --configuration .swift-format \
        --recursive \
        --parallel \
        --in-place \
        {{SWIFT_PATHS}}
    @echo ""
    @echo "Formatting applied. Re-run 'just lint' to confirm nothing is left."

# CI step: String Catalog translation coverage
locales *ARGS:
    scripts/ci/check-localizations.sh {{ARGS}}

# CI step: macOS project sanity checks
sanity:
    scripts/ci/macos-sanity-checks.sh

# CI step: Unit tests (PR test plan, with code coverage)
test:
    rm -rf TestResults.xcresult
    xcodebuild test \
        -project "{{PROJECT}}" \
        -scheme "{{SCHEME}}" \
        -testPlan PR \
        -destination "{{DESTINATION}}" \
        -resultBundlePath TestResults.xcresult \
        -enableCodeCoverage YES \
        CODE_SIGNING_ALLOWED=NO

# CI step: Release build smoke (arm64)
build-release:
    xcodebuild build \
        -project "{{PROJECT}}" \
        -scheme "{{SCHEME}}" \
        -configuration Release \
        -destination "{{DESTINATION}}" \
        ARCHS=arm64 \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=NO

# CI job: Static analysis — analyze the Debug build
analyze:
    xcodebuild analyze \
        -project "{{PROJECT}}" \
        -scheme "{{SCHEME}}" \
        -configuration Debug \
        -destination "{{DESTINATION}}" \
        CODE_SIGNING_ALLOWED=NO

# Reads the TestResults.xcresult bundle `just test` leaves behind, so run that
# first. Pass --min N to gate on an absolute floor locally; CI gates on the
# delta against master instead.
# CI job: Coverage — line coverage of the app target
coverage *ARGS:
    scripts/ci/coverage.sh {{ARGS}}

# Repin MarmotKit to a published mdk release (version or full master SHA).
# Not part of precommit — run it deliberately when moving the core.
sync-bindings REF:
    scripts/sync-bindings.sh {{REF}}

# CI step: Show Xcode environment (informational; not part of precommit)
env:
    sw_vers
    xcodebuild -version
    xcodebuild -showsdks
    xcodebuild -list -project "{{PROJECT}}"
    xcodebuild -showTestPlans -project "{{PROJECT}}" -scheme "{{SCHEME}}"
