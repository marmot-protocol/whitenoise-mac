# Local mirror of .github/workflows/mac-ci.yml.
# Keep the recipes below in sync with that workflow so `just precommit`
# stays a faithful predictor of the GitHub Actions result.

PROJECT := "whitenoise-mac.xcodeproj"
SCHEME := "whitenoise-mac"
DESTINATION := "platform=macOS"

# Source roots checked by swift-format (matches the "Swift format lint" CI step).
SWIFT_PATHS := "whitenoise-mac whitenoise-macTests whitenoise-macUITests"

default: precommit

# List available recipes
help:
    @just --list

# Run everything CI runs on a PR — both the "PR Checks" and "Static Analysis" jobs
precommit: lint locales sanity test build-release analyze
    @echo ""
    @echo "✅ precommit passed — mac-ci.yml should be green."

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

# CI job: Static Analysis — analyze the Debug build
analyze:
    xcodebuild analyze \
        -project "{{PROJECT}}" \
        -scheme "{{SCHEME}}" \
        -configuration Debug \
        -destination "{{DESTINATION}}" \
        CODE_SIGNING_ALLOWED=NO

# CI step: Show Xcode environment (informational; not part of precommit)
env:
    sw_vers
    xcodebuild -version
    xcodebuild -showsdks
    xcodebuild -list -project "{{PROJECT}}"
    xcodebuild -showTestPlans -project "{{PROJECT}}" -scheme "{{SCHEME}}"
