#!/bin/bash
set -euo pipefail

# Rebuilds the test bundle only when sources changed, then runs the named suites.
# Without arguments it runs the whole TableProTests target.
#
#   scripts/test-fast.sh                                  # everything
#   scripts/test-fast.sh GridAggregateCalculatorTests     # one suite
#   scripts/test-fast.sh Suite/testName                   # one test

DERIVED_DATA="${DERIVED_DATA:-/tmp/ss-dd}"
PROJECT="SchemaStudio.xcodeproj"
SCHEME="SchemaStudio"

COMMON=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -derivedDataPath "$DERIVED_DATA"
    -skipPackagePluginValidation
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=
)

if [[ "${REBUILD:-0}" == "1" || ! -d "$DERIVED_DATA/Build/Products" ]]; then
    echo "Building test bundle into $DERIVED_DATA ..."
    xcodebuild "${COMMON[@]}" build-for-testing > /tmp/test-fast-build.log 2>&1 || {
        grep -E "error:" /tmp/test-fast-build.log | head -20
        echo "Build failed. Full log: /tmp/test-fast-build.log"
        exit 1
    }
fi

TESTING=()
if [[ $# -gt 0 ]]; then
    for target in "$@"; do
        TESTING+=(-only-testing:"TableProTests/$target")
    done
else
    TESTING+=(-only-testing:TableProTests)
fi

set +e
xcodebuild "${COMMON[@]}" test-without-building \
    -parallel-testing-enabled NO \
    "${TESTING[@]}" > /tmp/test-fast.log 2>&1
status=$?
set -e

{ sed -n '/Failing tests:/,/TEST EXECUTE FAILED/p' /tmp/test-fast.log \
    | grep -oE "^\s+\S+" | tr -d '\t ' | sort -u || true; } > /tmp/test-fast-failures.txt

passed=$(grep -c "passed" /tmp/test-fast.log || true)
failed=$(wc -l < /tmp/test-fast-failures.txt | tr -d ' ')

echo "passed: $passed    failed: $failed"
if [[ "$failed" != "0" ]]; then
    cat /tmp/test-fast-failures.txt
    echo "Full log: /tmp/test-fast.log"
fi

exit $status
