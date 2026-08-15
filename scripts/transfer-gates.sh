#!/usr/bin/env bash
#
# Runs the transfer gates that need a real server.
#
# The gates are off unless a marker file exists. The scheme's test action uses
# the launch action's environment, which replaces whatever xcodebuild was
# invoked with, so passing TRANSFER_GATES=1 on the command line does not reach
# the test process: the gates skip and still report as passed. The marker file
# is read the same way from every runner.
#
# Usage:
#   scripts/transfer-gates.sh                     all gates
#   scripts/transfer-gates.sh TransferSnapshotGateTests
#   scripts/transfer-gates.sh TransferLiveServerGateTests/mysqlMillionRowCopy
#
set -euo pipefail

cd "$(dirname "$0")/.."

MARKER="/tmp/schemastudio-transfer-gates"
SCHEME="${SCHEME:-SchemaStudio}"
PROJECT="${PROJECT:-SchemaStudio.xcodeproj}"
RESULT_BUNDLE="${RESULT_BUNDLE:-${TMPDIR:-/tmp}/transfer-gates.xcresult}"

TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(TransferLiveServerGateTests TransferSnapshotGateTests)

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
    >"${TMPDIR:-/tmp}/transfer-gates.log" 2>&1
status=$?
set -e

# Test output does not reach xcodebuild's stdout, so the measurements and any
# failure messages have to be read back out of the result bundle.
xcrun xcresulttool get test-results tests --path "$RESULT_BUNDLE" --format json 2>/dev/null \
    | python3 -c '
import json, sys

data = json.load(sys.stdin)

def walk(node, suite=""):
    kind = node.get("nodeType")
    name = node.get("name", "")
    if kind == "Test Suite":
        suite = name
    if kind == "Test Case":
        result = node.get("result", "?")
        print("  %-8s %s / %s" % (result, suite, name))
    if kind == "Failure Message":
        print("           " + name)
    for child in node.get("children", []):
        walk(child, suite)

for node in data.get("testNodes", []):
    walk(node)
'

if [ $status -ne 0 ]; then
    echo "Gates failed. Full log: ${TMPDIR:-/tmp}/transfer-gates.log" >&2
fi
exit $status
