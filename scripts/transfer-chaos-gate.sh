#!/usr/bin/env bash
#
# The chaos gate: start a transfer, kill the process outright, then resume in a
# fresh process and check the target.
#
# `cancel()` unwinds cooperatively, so the in-suite resume test cannot prove
# that a hard-killed app recovers. This kills the test runner with SIGKILL,
# which gives it no chance to flush anything, and then runs the verify phase as
# a separate process that only has the checkpoint file to work from.
#
# Usage: scripts/transfer-chaos-gate.sh [kill-delay-seconds]
#
set -euo pipefail

cd "$(dirname "$0")/.."

KILL_DELAY="${1:-6}"
SCHEME="${SCHEME:-SchemaStudio}"
PROJECT="${PROJECT:-SchemaStudio.xcodeproj}"
LOG_DIR="${TMPDIR:-/tmp}/transfer-chaos-gate"
MARKER="/tmp/schemastudio-transfer-gates"
mkdir -p "$LOG_DIR"
trap 'rm -f "$MARKER"' EXIT

# The marker file carries both "gates are on" and which phase to run: the
# scheme's test action replaces the environment xcodebuild was invoked with, so
# neither TRANSFER_GATES nor TRANSFER_CHAOS_PHASE survives as a command-line
# argument.
run_phase() {
    local phase="$1"
    local test_name="$2"
    local log="$LOG_DIR/$phase.log"
    printf '%s' "$phase" >"$MARKER"
    rm -rf "$LOG_DIR/$phase.xcresult"
    # The pid has to come back through a variable, not command substitution: a
    # subshell's $! is not a child of this shell and cannot be waited on.
    xcodebuild test \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -skipPackagePluginValidation \
        -only-testing:"TableProTests/TransferChaosGateTests/$test_name" \
        -parallel-testing-enabled NO \
        -resultBundlePath "$LOG_DIR/$phase.xcresult" \
        >"$log" 2>&1 &
    PHASE_PID=$!
}

# Test output does not reach xcodebuild's stdout, so results have to be read
# back out of the result bundle.
report_phase() {
    xcrun xcresulttool get test-results tests --path "$LOG_DIR/$1.xcresult" --format json 2>/dev/null \
        | python3 -c '
import json, sys

data = json.load(sys.stdin)

def walk(node):
    kind = node.get("nodeType")
    name = node.get("name", "")
    if kind == "Test Case":
        print("  %-8s %s" % (node.get("result", "?"), name))
    if kind == "Failure Message":
        print("           " + name)
    for child in node.get("children", []):
        walk(child)

for node in data.get("testNodes", []):
    walk(node)
'
}

target_rows() {
    docker exec "${MYSQL_CONTAINER:-tornado.mysql}" \
        mysql -uroot -proot -N -B -e "SELECT COUNT(*) FROM ss_gate_dst.bench" 2>/dev/null || echo 0
}

# Empty the target up front. The run phase truncates it too, but the poll below
# uses "rows exist" as the signal that the transfer is underway, and rows left
# by an earlier run would fire that signal before this run wrote anything.
echo "==> Emptying the target"
docker exec "${MYSQL_CONTAINER:-tornado.mysql}" \
    mysql -uroot -proot -e "TRUNCATE ss_gate_dst.bench" 2>/dev/null

echo "==> Phase 1: transfer, killed after ${KILL_DELAY}s"
run_phase run "chaosRunPhase()"
build_pid=$PHASE_PID

# Wait for rows to actually be committed at the target rather than for a fixed
# delay: the kill has to land after at least one chunk committed, otherwise
# there is no checkpoint to resume from and the gate would be testing nothing.
# Test output never reaches xcodebuild's stdout, so the target itself is the
# only honest progress signal.
deadline=$((SECONDS + 900))
while [ $SECONDS -lt $deadline ]; do
    rows=$(target_rows)
    [ "${rows:-0}" -gt 0 ] && break
    if ! kill -0 "$build_pid" 2>/dev/null; then
        echo "Phase 1 exited before writing any rows. Log: $LOG_DIR/run.log" >&2
        tail -40 "$LOG_DIR/run.log" >&2
        exit 1
    fi
    sleep 1
done

rows=$(target_rows)
if [ "${rows:-0}" -eq 0 ]; then
    echo "The transfer never committed a row. Log: $LOG_DIR/run.log" >&2
    exit 1
fi

# The runner is a child of xcodebuild, so killing xcodebuild is not enough: the
# transfer would keep going in the xctest process and finish the table.
xctest_pid=$(pgrep -f "SchemaStudio.app/Contents/MacOS/SchemaStudio" | head -1 || true)
if [ -z "$xctest_pid" ]; then
    echo "Could not find the test host process to kill." >&2
    exit 1
fi

echo "    $rows rows committed, transfer is pid $xctest_pid, killing in ${KILL_DELAY}s"
sleep "$KILL_DELAY"
kill -9 "$xctest_pid" 2>/dev/null || true
wait "$build_pid" 2>/dev/null || true
echo "    killed"

echo "==> Phase 2: resume in a fresh process"
run_phase verify "chaosVerifyPhase()"
verify_pid=$PHASE_PID
if wait "$verify_pid"; then
    report_phase verify
    echo "==> Chaos gate passed"
else
    report_phase verify >&2
    echo "==> Chaos gate FAILED. Log: $LOG_DIR/verify.log" >&2
    exit 1
fi
