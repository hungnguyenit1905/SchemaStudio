#!/usr/bin/env bash
#
# Runs the duplicate gates that need a real server.
#
# The gates are off unless a marker file exists. The scheme's test action uses
# the launch action's environment, which replaces whatever xcodebuild was
# invoked with, so passing DUPLICATE_GATES=1 on the command line does not reach
# the test process: the gates skip and still report as passed. The marker file
# is read the same way from every runner.
#
# The servers are the ones scripts/transfer-gate-fixtures.sh prepares:
#   MySQL      ss_gate_src on 127.0.0.1:33062 as root
#   PostgreSQL ss_gate_src on 127.0.0.1:5432  as postgres
# Every table these gates need is created and dropped by the test itself.
#
# Usage:
#   scripts/duplicate-gates.sh                     all gates
#   scripts/duplicate-gates.sh DuplicateIndexFidelityGateTests
#   scripts/duplicate-gates.sh DuplicateLiveServerGateTests/rowsAndSequenceMatch
#
set -euo pipefail

cd "$(dirname "$0")/.."

MARKER="/tmp/schemastudio-duplicate-gates"
SCHEME="${SCHEME:-SchemaStudio}"
PROJECT="${PROJECT:-SchemaStudio.xcodeproj}"
RESULT_BUNDLE="${RESULT_BUNDLE:-${TMPDIR:-/tmp}/duplicate-gates.xcresult}"

TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(
    DuplicateIndexFidelityGateTests
    DuplicatePreviewParityGateTests
    DuplicateLiveServerGateTests
)

only_testing=()
for target in "${TARGETS[@]}"; do
    only_testing+=("-only-testing:TableProTests/$target")
done

touch "$MARKER"
trap 'rm -f "$MARKER"' EXIT

rm -rf "$RESULT_BUNDLE"
set +e
xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -skipPackagePluginValidation \
    "${only_testing[@]}" \
    -parallel-testing-enabled NO \
    -resultBundlePath "$RESULT_BUNDLE" \
    >"${TMPDIR:-/tmp}/duplicate-gates.log" 2>&1
status=$?
set -e

# Test output does not reach xcodebuild's stdout, so the results have to be read
# back out of the result bundle. A gate that skipped for want of a server still
# reports as passed, so the count printed at the end is what tells you whether
# anything actually ran against a database.
xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" --format json 2>/dev/null \
    | python3 -c '
import json, sys

data = json.load(sys.stdin)
cases = 0

def walk(node, suite=""):
    global cases
    kind = node.get("nodeType")
    name = node.get("name", "")
    if kind == "Test Suite":
        suite = name
    if kind == "Test Case":
        cases += 1
        result = node.get("result", "?")
        print("  %-8s %s / %s" % (result, suite, name))
    if kind == "Failure Message":
        print("           " + name)
    for child in node.get("children", []):
        walk(child, suite)

for node in data.get("testNodes", []):
    walk(node)

print("  %d test case(s) ran" % cases)
'

if [ $status -ne 0 ]; then
    echo "Gates failed. Full log: ${TMPDIR:-/tmp}/duplicate-gates.log" >&2
fi
exit $status
