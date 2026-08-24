#!/usr/bin/env bash
#
# Runs the suite and fails on ANY failure, swift-testing or XCTest.
#
# `swift test` exits non-zero on either, but its output does not: swift-testing
# prints a "Test run with N tests" summary last, and XCTest prints "Executed N
# tests, with M failures" earlier. Grepping for the summary you expect is how a
# failing macro-fixture suite hides behind a green swift-testing line — which
# is exactly what happened to 13 fixtures here.
#
# So: trust the exit code, and report both dialects.
#
set -uo pipefail
cd "$(dirname "$0")/.."

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

swift test --enable-all-traits "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}

echo ""
echo "── summary"
grep -E "Test run with [0-9]+ tests" "$log" | tail -1 | sed 's/^/  swift-testing: /' || true
xctest=$(grep -oE "Executed [0-9]+ tests, with [0-9]+ failures" "$log" | tail -1)
[ -n "$xctest" ] && echo "  XCTest:        $xctest"

if grep -qE "Executed [0-9]+ tests, with [1-9][0-9]* failures" "$log"; then
  echo "::error::XCTest reported failures — these do not appear in the swift-testing summary"
  status=1
fi

exit $status
